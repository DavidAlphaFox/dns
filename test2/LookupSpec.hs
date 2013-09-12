{-# LANGUAGE OverloadedStrings #-}

module LookupSpec where

import qualified Data.ByteString.Char8 as BS
import Network.DNS as DNS
import Test.Hspec

spec :: Spec
spec = do

    describe "lookupAAAA" $ do
        it "gets IPv6 addresses" $ do
            rs <- makeResolvSeed defaultResolvConf
            withResolver rs $ \resolver -> do
                DNS.lookupAAAA resolver "mew.org"
                    `shouldReturn`
                    Right []

    describe "lookupSRV" $ do
        it "gets SRV" $ do
            rs <- makeResolvSeed defaultResolvConf
            withResolver rs $ \resolver ->
                DNS.lookupSRV resolver "_sip._tcp.cisco.com"
                    `shouldReturn`
                    Right [(1,0,5060,"vcsgw.cisco.com.")]
