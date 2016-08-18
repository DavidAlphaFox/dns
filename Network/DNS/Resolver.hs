{-# LANGUAGE CPP, OverloadedStrings #-}

-- | DNS Resolver and generic (lower-level) lookup functions.
module Network.DNS.Resolver (
  -- * Documentation
  -- ** Configuration for resolver
    FileOrNumericHost(..), ResolvConf(..), defaultResolvConf
  -- ** Intermediate data type for resolver
  , ResolvSeed, makeResolvSeed
  -- ** Type and function for resolver
  , Resolver(..), withResolver, withResolvers
  -- ** Looking up functions
  , lookup
  , lookupAuth
  -- ** Raw looking up function
  , lookupRaw
  , lookupRawAD
  , fromDNSMessage
  , fromDNSFormat
  ) where

import Control.Exception (bracket)
import Data.Char (isSpace)
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import Network.BSD (getProtocolNumber)
import Network.DNS.Decode
import Network.DNS.Encode
import Network.DNS.Internal
import qualified Data.ByteString.Char8 as BS
import Network.Socket (HostName, Socket, SocketType(Datagram), sClose, socket, connect)
import Network.Socket (AddrInfoFlag(..), AddrInfo(..), SockAddr(..), PortNumber(..), defaultHints, getAddrInfo)
import Prelude hiding (lookup)
import System.Random (getStdRandom, randomR)
import System.Timeout (timeout)

#if __GLASGOW_HASKELL__ < 709
import Control.Applicative ((<$>), (<*>), pure)
#endif

#if mingw32_HOST_OS == 1
import Network.Socket (send)
import qualified Data.ByteString.Lazy.Char8 as LB
import Control.Monad (when)
#else
import Network.Socket.ByteString.Lazy (sendAll)
#endif

----------------------------------------------------------------


-- | Union type for 'FilePath' and 'HostName'. Specify 'FilePath' to
--   \"resolv.conf\" or numeric IP address in 'String' form.
--
--   /Warning/: Only numeric IP addresses are valid @RCHostName@s.
--
--   Example (using Google's public DNS cache):
--
--   >>> let cache = RCHostName "8.8.8.8"
--
data FileOrNumericHost = RCFilePath FilePath -- ^ A path for \"resolv.conf\"
                       | RCHostName HostName -- ^ A numeric IP address
                       | RCHostPort HostName PortNumber -- ^ A numeric IP address and port number

-- | Type for resolver configuration. The easiest way to construct a
--   @ResolvConf@ object is to modify the 'defaultResolvConf'.
data ResolvConf = ResolvConf {
    resolvInfo :: FileOrNumericHost
   -- | Timeout in micro seconds.
  , resolvTimeout :: Int
   -- | The number of retries including the first try.
  , resolvRetry :: Int
   -- | This field was obsoleted.
  , resolvBufsize :: Integer
}


-- | Return a default 'ResolvConf':
--
--     * 'resolvInfo' is 'RCFilePath' \"\/etc\/resolv.conf\".
--
--     * 'resolvTimeout' is 3,000,000 micro seconds.
--
--     * 'resolvRetry' is 3.
--
--     * 'resolvBufsize' is 512. (obsoleted)
--
--  Example (use Google's public DNS cache instead of resolv.conf):
--
--   >>> let cache = RCHostName "8.8.8.8"
--   >>> let rc = defaultResolvConf { resolvInfo = cache }
--
defaultResolvConf :: ResolvConf
defaultResolvConf = ResolvConf {
    resolvInfo = RCFilePath "/etc/resolv.conf"
  , resolvTimeout = 3 * 1000 * 1000
  , resolvRetry = 3
  , resolvBufsize = 512
}

----------------------------------------------------------------

-- | Abstract data type of DNS Resolver seed.
--   When implementing a DNS cache, this should be re-used.
data ResolvSeed = ResolvSeed {
    addrInfo :: AddrInfo
  , rsTimeout :: Int
  , rsRetry :: Int
  , rsBufsize :: Integer
}

-- | Abstract data type of DNS Resolver
--   When implementing a DNS cache, this MUST NOT be re-used.
data Resolver = Resolver {
    genId   :: IO Int
  , dnsSock :: Socket
  , dnsTimeout :: Int
  , dnsRetry :: Int
  , dnsBufsize :: Integer
}

----------------------------------------------------------------


-- |  Make a 'ResolvSeed' from a 'ResolvConf'.
--
--    Examples:
--
--    >>> rs <- makeResolvSeed defaultResolvConf
--
makeResolvSeed :: ResolvConf -> IO ResolvSeed
makeResolvSeed conf = ResolvSeed <$> addr
                                 <*> pure (resolvTimeout conf)
                                 <*> pure (resolvRetry conf)
                                 <*> pure (resolvBufsize conf)
  where
    addr = case resolvInfo conf of
        RCHostName numhost -> makeAddrInfo numhost Nothing
        RCHostPort numhost mport -> makeAddrInfo numhost $ Just mport
        RCFilePath file -> toAddr <$> readFile file >>= \i -> makeAddrInfo i Nothing
    toAddr cs = let l:_ = filter ("nameserver" `isPrefixOf`) $ lines cs
                in extract l
    extract = reverse . dropWhile isSpace . reverse . dropWhile isSpace . drop 11

makeAddrInfo :: HostName -> Maybe PortNumber -> IO AddrInfo
makeAddrInfo addr mport = do
    proto <- getProtocolNumber "udp"
    let hints = defaultHints {
            addrFlags = [AI_ADDRCONFIG, AI_NUMERICHOST, AI_PASSIVE]
          , addrSocketType = Datagram
          , addrProtocol = proto
          }
    a:_ <- getAddrInfo (Just hints) (Just addr) (Just "domain")
    let connectPort = case addrAddress a of
                        SockAddrInet pn ha -> SockAddrInet (fromMaybe pn mport) ha
                        SockAddrInet6 pn fi ha sid -> SockAddrInet6 (fromMaybe pn mport) fi ha sid
                        unixAddr -> unixAddr
    return $ a { addrAddress = connectPort }

----------------------------------------------------------------


-- | Giving a thread-safe 'Resolver' to the function of the second
--   argument. A socket for UDP is opened inside and is surely closed.
--   Multiple 'withResolver's can be used concurrently.
--   Multiple lookups must be done sequentially with a given
--   'Resolver'. If multiple 'Resolver's are necessary for
--   concurrent purpose, use 'withResolvers'.
withResolver :: ResolvSeed -> (Resolver -> IO a) -> IO a
withResolver seed func = bracket (openSocket seed) sClose $ \sock -> do
    connectSocket sock seed
    func $ makeResolver seed sock

-- | Giving thread-safe 'Resolver's to the function of the second
--   argument. Sockets for UDP are opened inside and are surely closed.
--   For each 'Resolver', multiple lookups must be done sequentially.
--   'Resolver's can be used concurrently.
withResolvers :: [ResolvSeed] -> ([Resolver] -> IO a) -> IO a
withResolvers seeds func = bracket openSockets closeSockets $ \socks -> do
    mapM_ (uncurry connectSocket) $ zip socks seeds
    let resolvs = zipWith makeResolver seeds socks
    func resolvs
  where
    openSockets = mapM openSocket seeds
    closeSockets = mapM sClose

openSocket :: ResolvSeed -> IO Socket
openSocket seed = socket (addrFamily ai) (addrSocketType ai) (addrProtocol ai)
  where
    ai = addrInfo seed

connectSocket :: Socket -> ResolvSeed -> IO ()
connectSocket sock seed = connect sock (addrAddress ai)
  where
    ai = addrInfo seed

makeResolver :: ResolvSeed -> Socket -> Resolver
makeResolver seed sock = Resolver {
    genId = getRandom
  , dnsSock = sock
  , dnsTimeout = rsTimeout seed
  , dnsRetry = rsRetry seed
  , dnsBufsize = rsBufsize seed
  }

getRandom :: IO Int
getRandom = getStdRandom (randomR (0,65535))

----------------------------------------------------------------

-- | Looking up resource records of a domain. The first parameter is one of
--   the field accessors of the 'DNSMessage' type -- this allows you to
--   choose which section (answer, authority, or additional) you would like
--   to inspect for the result.

lookupSection :: (DNSMessage -> [ResourceRecord])
              -> Resolver
              -> Domain
              -> TYPE
              -> IO (Either DNSError [RData])
lookupSection section rlv dom typ = do
    eans <- lookupRaw rlv dom typ
    case eans of
        Left  err -> return $ Left err
        Right ans -> return $ fromDNSMessage ans toRData
  where
    {- CNAME hack
    dom' = if "." `isSuffixOf` dom then dom else dom ++ "."
    correct r = rrname r == dom' && rrtype r == typ
    -}
    correct r = rrtype r == typ
    toRData = map rdata . filter correct . section

-- | Extract necessary information from 'DNSMessage'
fromDNSMessage :: DNSMessage -> (DNSMessage -> a) -> Either DNSError a
fromDNSMessage ans conv = case errcode ans of
    NoErr     -> Right $ conv ans
    FormatErr -> Left FormatError
    ServFail  -> Left ServerFailure
    NameErr   -> Left NameError
    NotImpl   -> Left NotImplemented
    Refused   -> Left OperationRefused
    BadOpt    -> Left BadOptRecord
  where
    errcode = rcode . flags . header

-- | For backward compatibility.
fromDNSFormat :: DNSMessage -> (DNSMessage -> a) -> Either DNSError a
fromDNSFormat = fromDNSMessage

-- | Look up resource records for a domain, collecting the results
--   from the ANSWER section of the response.
--
--   We repeat an example from "Network.DNS.Lookup":
--
--   >>> let hostname = Data.ByteString.Char8.pack "www.example.com"
--   >>> rs <- makeResolvSeed defaultResolvConf
--   >>> withResolver rs $ \resolver -> lookup resolver hostname A
--   Right [93.184.216.34]
--
lookup :: Resolver -> Domain -> TYPE -> IO (Either DNSError [RData])
lookup = lookupSection answer

-- | Look up resource records for a domain, collecting the results
--   from the AUTHORITY section of the response.
lookupAuth :: Resolver -> Domain -> TYPE -> IO (Either DNSError [RData])
lookupAuth = lookupSection authority


-- | Look up a name and return the entire DNS Response. Sample output
--   is included below, however it is /not/ tested -- the sequence
--   number is unpredictable (it has to be!).
--
--   The example code:
--
--   @
--   let hostname = Data.ByteString.Char8.pack \"www.example.com\"
--   rs <- makeResolvSeed defaultResolvConf
--   withResolver rs $ \resolver -> lookupRaw resolver hostname A
--   @
--
--   And the (formatted) expected output:
--
--   @
--   Right (DNSMessage
--           { header = DNSHeader
--                        { identifier = 1,
--                          flags = DNSFlags
--                                    { qOrR = QR_Response,
--                                      opcode = OP_STD,
--                                      authAnswer = False,
--                                      trunCation = False,
--                                      recDesired = True,
--                                      recAvailable = True,
--                                      rcode = NoErr,
--                                      authenData = False
--                                    },
--                        },
--             question = [Question { qname = \"www.example.com.\",
--                                    qtype = A}],
--             answer = [ResourceRecord {rrname = \"www.example.com.\",
--                                       rrtype = A,
--                                       rrttl = 800,
--                                       rdlen = 4,
--                                       rdata = 93.184.216.119}],
--             authority = [],
--             additional = []})
--  @
--
lookupRaw :: Resolver -> Domain -> TYPE -> IO (Either DNSError DNSMessage)
lookupRaw = lookupRawInternal receive False

lookupRawAD :: Resolver -> Domain -> TYPE -> IO (Either DNSError DNSMessage)
lookupRawAD = lookupRawInternal receive True



lookupRawInternal ::
    (Socket -> IO DNSMessage)
    -> Bool
    -> Resolver
    -> Domain
    -> TYPE
    -> IO (Either DNSError DNSMessage)
lookupRawInternal _ _ _   dom _
  | isIllegal dom     = return $ Left IllegalDomain
lookupRawInternal rcv ad rlv dom typ = do
    seqno <- genId rlv
    let query = (if ad then composeQueryAD else composeQuery) seqno [q]
        checkSeqno = check seqno
    loop query checkSeqno 0 False
  where
    loop query checkSeqno cnt mismatch
      | cnt == retry = do
          let ret | mismatch  = SequenceNumberMismatch
                  | otherwise = TimeoutExpired
          return $ Left ret
      | otherwise    = do
          sendAll sock query
          response <- timeout tm (rcv sock)
          case response of
              Nothing  -> loop query checkSeqno (cnt + 1) False
              Just res -> do
                  let valid = checkSeqno res
                  if valid then
                      return $ Right res
                    else
                      loop query checkSeqno (cnt + 1) False
    sock = dnsSock rlv
    tm = dnsTimeout rlv
    retry = dnsRetry rlv
    q = makeQuestion dom typ
    check seqno res = identifier (header res) == seqno

#if mingw32_HOST_OS == 1
    -- Windows does not support sendAll in Network.ByteString.Lazy.
    -- This implements sendAll with Haskell Strings.
    sendAll sock bs = do
	sent <- send sock (LB.unpack bs)
	when (sent < fromIntegral (LB.length bs)) $ sendAll sock (LB.drop (fromIntegral sent) bs)
#endif

isIllegal :: Domain -> Bool
isIllegal ""                    = True
isIllegal dom
  | '.' `BS.notElem` dom        = True
  | ':' `BS.elem` dom           = True
  | '/' `BS.elem` dom           = True
  | BS.length dom > 253         = True
  | any (\x -> BS.length x > 63)
        (BS.split '.' dom)      = True
isIllegal _                     = False
