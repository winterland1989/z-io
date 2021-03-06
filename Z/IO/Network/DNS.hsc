{-|
Module      : Z.IO.Network.DNS
Description : DNS and reverse DNS
Copyright   : (c) Winterland, 2018
License     : BSD
Maintainer  : winterland1989@gmail.com
Stability   : experimental
Portability : non-portable

This module provides 'getAddrInfo' and 'getNameInfo'. <https://www.man7.org/linux/man-pages/man3/getnameinfo.3.html getnameinfo> and <https://man7.org/linux/man-pages/man3/getaddrinfo.3.html getaddrinfo> equivalent.

-}
module Z.IO.Network.DNS (
  -- * name to ip
    getAddrInfo
  , HostName
  , ServiceName
  , AddrInfoFlag(..), addrInfoFlagImplemented, addrInfoFlagMapping
  , AddrInfo(..), defaultHints, followAddrInfo
  -- * ip to name
  , getNameInfo
  , NameInfoFlag(..), nameInfoFlagMapping
  ) where

import           Data.Bits
import           Data.List                  as List
import           Data.Word
import           Foreign.C.Types
import           Foreign.Marshal.Utils
import           Foreign.Ptr
import           Foreign.Storable 
import           GHC.Generics
import           Z.Data.CBytes              as CBytes
import           Z.Data.Text.Print          (Print(..))
import           Z.Data.JSON                (JSON)
import           Z.Foreign
import           Z.IO.Exception
import           Z.IO.Network.SocketAddr
import           Z.IO.UV.Win

#include "hs_uv.h"

-----------------------------------------------------------------------------

-- | Either a host name e.g., @\"haskell.org\"@ or a numeric host
-- address string consisting of a dotted decimal IPv4 address or an
-- IPv6 address e.g., @\"192.168.0.1\"@.
type HostName       = CBytes
-- | Either a service name e.g., @\"http\"@ or a numeric port number.
type ServiceName    = CBytes

-----------------------------------------------------------------------------
-- Address and service lookups

-- | Flags that control the querying behaviour of 'getAddrInfo'.
--   For more information, see <https://tools.ietf.org/html/rfc3493#page-25>
data AddrInfoFlag =
    -- | The list of returned 'AddrInfo' values will
    --   only contain IPv4 addresses if the local system has at least
    --   one IPv4 interface configured, and likewise for IPv6.
    --   (Only some platforms support this.)
      AI_ADDRCONFIG
    -- | If 'AI_ALL' is specified, return all matching IPv6 and
    --   IPv4 addresses.  Otherwise, this flag has no effect.
    --   (Only some platforms support this.)
    | AI_ALL
    -- | The 'addrCanonName' field of the first returned
    --   'AddrInfo' will contain the "canonical name" of the host.
    | AI_CANONNAME
    -- | The 'HostName' argument /must/ be a numeric
    --   address in string form, and network name lookups will not be
    --   attempted.
    | AI_NUMERICHOST
    -- | The 'ServiceName' argument /must/ be a port
    --   number in string form, and service name lookups will not be
    --   attempted. (Only some platforms support this.)
    | AI_NUMERICSERV
    -- | If no 'HostName' value is provided, the network
    --   address in each 'SocketAddr'
    --   will be left as a "wild card".
    --   This is useful for server applications that
    --   will accept connections from any client.
    | AI_PASSIVE
    -- | If an IPv6 lookup is performed, and no IPv6
    --   addresses are found, IPv6-mapped IPv4 addresses will be
    --   returned. (Only some platforms support this.)
    | AI_V4MAPPED
    deriving (Eq, Ord, Read, Show, Generic)
    deriving anyclass (Print, JSON)

addrInfoFlagMapping :: [(AddrInfoFlag, CInt)]
addrInfoFlagMapping =
    [
#ifdef AI_ADDRCONFIG
     (AI_ADDRCONFIG, #const AI_ADDRCONFIG),
#else
     (AI_ADDRCONFIG, 0),
#endif
#ifdef AI_ALL
     (AI_ALL, #const AI_ALL),
#else
     (AI_ALL, 0),
#endif
     (AI_CANONNAME, #const AI_CANONNAME),
     (AI_NUMERICHOST, #const AI_NUMERICHOST),
#ifdef AI_NUMERICSERV
     (AI_NUMERICSERV, #const AI_NUMERICSERV),
#else
     (AI_NUMERICSERV, 0),
#endif
     (AI_PASSIVE, #const AI_PASSIVE),
#ifdef AI_V4MAPPED
     (AI_V4MAPPED, #const AI_V4MAPPED)
#else
     (AI_V4MAPPED, 0)
#endif
    ]

-- | Indicate whether the given 'AddrInfoFlag' will have any effect on this system.
addrInfoFlagImplemented :: AddrInfoFlag -> Bool
addrInfoFlagImplemented f = packBits addrInfoFlagMapping [f] /= 0

-- | Address info
data AddrInfo = AddrInfo {
    addrFlags :: [AddrInfoFlag]
  , addrFamily :: SocketFamily
  , addrSocketType :: SocketType
  , addrProtocol :: ProtocolNumber
  , addrAddress :: SocketAddr
  , addrCanonName :: CBytes
  } deriving (Eq, Ord, Show, Generic)
    deriving anyclass (Print, JSON)


instance Storable AddrInfo where
    sizeOf    _ = #const sizeof(struct addrinfo)
    alignment _ = alignment (0 :: CInt)

    peek p = do
        ai_flags <- (#peek struct addrinfo, ai_flags) p
        ai_family <- (#peek struct addrinfo, ai_family) p
        ai_socktype <- (#peek struct addrinfo, ai_socktype) p
        ai_protocol <- (#peek struct addrinfo, ai_protocol) p
        ai_addr <- (#peek struct addrinfo, ai_addr) p >>= peekSocketAddr
        ai_canonname_ptr <- (#peek struct addrinfo, ai_canonname) p
        ai_canonname <- fromCString ai_canonname_ptr

        return $ AddrInfo {
            addrFlags = unpackBits addrInfoFlagMapping ai_flags
          , addrFamily = ai_family
          , addrSocketType = ai_socktype
          , addrProtocol = ai_protocol
          , addrAddress = ai_addr
          , addrCanonName = ai_canonname
          }

    poke p (AddrInfo flags family sockType protocol _ _) = do
        (#poke struct addrinfo, ai_flags) p (packBits addrInfoFlagMapping flags)
        (#poke struct addrinfo, ai_family) p family
        (#poke struct addrinfo, ai_socktype) p sockType
        (#poke struct addrinfo, ai_protocol) p protocol
        -- stuff below is probably not needed, but let's zero it for safety
        (#poke struct addrinfo, ai_addrlen) p (0::CSize)
        (#poke struct addrinfo, ai_addr) p nullPtr
        (#poke struct addrinfo, ai_canonname) p nullPtr
        (#poke struct addrinfo, ai_next) p nullPtr

-- | Flags that control the querying behaviour of 'getNameInfo'.
--   For more information, see <https://tools.ietf.org/html/rfc3493#page-30>
data NameInfoFlag =
    -- | Resolve a datagram-based service name.  This is
    --   required only for the few protocols that have different port
    --   numbers for their datagram-based versions than for their
    --   stream-based versions.
      NI_DGRAM
    -- | If the hostname cannot be looked up, an IO error is thrown.
    | NI_NAMEREQD
    -- | If a host is local, return only the hostname part of the FQDN.
    | NI_NOFQDN
    -- | The name of the host is not looked up.
    --   Instead, a numeric representation of the host's
    --   address is returned.  For an IPv4 address, this will be a
    --   dotted-quad string.  For IPv6, it will be colon-separated
    --   hexadecimal.
    | NI_NUMERICHOST
    -- | The name of the service is not
    --   looked up.  Instead, a numeric representation of the
    --   service is returned.
    | NI_NUMERICSERV
    deriving (Eq, Read, Show)

nameInfoFlagMapping :: [(NameInfoFlag, CInt)]

nameInfoFlagMapping = [(NI_DGRAM, #const NI_DGRAM),
                 (NI_NAMEREQD, #const NI_NAMEREQD),
                 (NI_NOFQDN, #const NI_NOFQDN),
                 (NI_NUMERICHOST, #const NI_NUMERICHOST),
                 (NI_NUMERICSERV, #const NI_NUMERICSERV)]

-- | Default hints for address lookup with 'getAddrInfo'.
--
-- >>> addrFlags defaultHints
-- []
-- >>> addrFamily defaultHints
-- AF_UNSPEC
-- >>> addrSocketType defaultHints
-- NoSocketType
-- >>> addrProtocol defaultHints
-- 0

defaultHints :: AddrInfo
defaultHints = AddrInfo {
    addrFlags      = []
  , addrFamily     = AF_UNSPEC
  , addrSocketType = SOCK_ANY
  , addrProtocol   = IPPROTO_DEFAULT
  , addrAddress    = SocketAddrIPv4 ipv4Any portAny
  , addrCanonName  = empty
  }

-----------------------------------------------------------------------------
-- | Resolve a host or service name to one or more addresses.
-- The 'AddrInfo' values that this function returns contain 'SocketAddr'
-- values that you can use to init TCP connection.
--
-- This function is protocol independent.  It can return both IPv4 and
-- IPv6 address information.
--
-- The 'AddrInfo' argument specifies the preferred query behaviour,
-- socket options, or protocol.  You can override these conveniently
-- using Haskell's record update syntax on 'defaultHints', for example
-- as follows:
--
-- >>> let hints = defaultHints { addrFlags = [AI_NUMERICHOST], addrSocketType = Stream }
--
-- You must provide non empty value for at least one of the 'HostName'
-- or 'ServiceName' arguments.  'HostName' can be either a numeric
-- network address (dotted quad for IPv4, colon-separated hex for
-- IPv6) or a hostname.  In the latter case, its addresses will be
-- looked up unless 'AI_NUMERICHOST' is specified as a hint.  If you
-- do not provide a 'HostName' value /and/ do not set 'AI_PASSIVE' as
-- a hint, network addresses in the result will contain the address of
-- the loopback interface.
--
-- If the query fails, this function throws an IO exception instead of
-- returning an empty list.  Otherwise, it returns a non-empty list
-- of 'AddrInfo' values.
--
-- There are several reasons why a query might result in several
-- values.  For example, the queried-for host could be multihomed, or
-- the service might be available via several protocols.
--
-- Note: the order of arguments is slightly different to that defined
-- for @getaddrinfo@ in RFC 2553.  The 'AddrInfo' parameter comes first
-- to make partial application easier.
--
-- >>> addr:_ <- getAddrInfo (Just hints) "127.0.0.1" "http"
-- >>> addrAddress addr
-- 127.0.0.1:80
--
getAddrInfo
    :: Maybe AddrInfo -- ^ preferred socket type or protocol
    -> HostName -- ^ host name to look up
    -> ServiceName -- ^ service name to look up
    -> IO [AddrInfo] -- ^ resolved addresses, with "best" first
getAddrInfo hints host service = withUVInitDo $
    bracket
        (do withCBytes host $ \ ptr_h ->
                withCBytes service $ \ ptr_s ->
                maybeWith with filteredHints $ \ ptr_hints ->
                fst <$> allocPrimSafe (\ ptr_ptr_addrs -> do
                    throwUVIfMinus_ $ hs_getaddrinfo ptr_h ptr_s ptr_hints ptr_ptr_addrs))
        freeaddrinfo
        followAddrInfo
  where
#if defined(darwin_HOST_OS)
    -- Leaving out the service and using AI_NUMERICSERV causes a
    -- segfault on OS X 10.8.2. This code removes AI_NUMERICSERV
    -- (which has no effect) in that case.
    toHints h = h { addrFlags = delete AI_NUMERICSERV (addrFlags h) }
    filteredHints = if CBytes.null service then toHints <$> hints else hints
#else
    filteredHints = hints
#endif

-- | Peek @addrinfo@ linked list.
--
followAddrInfo :: Ptr AddrInfo -> IO [AddrInfo]
followAddrInfo ptr_ai
    | ptr_ai == nullPtr = return []
    | otherwise = do
        !a  <- peek ptr_ai
        as <- (# peek struct addrinfo, ai_next) ptr_ai >>= followAddrInfo
        return (a : as)

-----------------------------------------------------------------------------


-- | Resolve an address to a host or service name.
-- This function is protocol independent.
-- The list of 'NameInfoFlag' values controls query behaviour.
--
-- If a host or service's name cannot be looked up, then the numeric
-- form of the address or service will be returned.
--
-- If the query fails, this function throws an IO exception.
--
-- >>> addr:_ <- getAddrInfo (Just defaultHints) "127.0.0.1" "http"
-- >>> getNameInfo [NI_NUMERICHOST, NI_NUMERICSERV] True True $ addrAddress addr
-- ("127.0.0.1", "80")
{-
-- >>> getNameInfo [] True True $ addrAddress addr
-- ("localhost", "http")
-}
getNameInfo
    :: [NameInfoFlag] -- ^ flags to control lookup behaviour
    -> Bool -- ^ whether to look up a hostname
    -> Bool -- ^ whether to look up a service name
    -> SocketAddr -- ^ the address to look up
    -> IO (HostName, ServiceName)
getNameInfo flags doHost doService addr = withUVInitDo $ do
    (host, (service, _)) <- allocCBytes (fromIntegral h_len) $ \ ptr_h ->
        allocCBytes (fromIntegral s_len) $ \ ptr_s ->
        withSocketAddr addr $ \ ptr_addr -> 
            throwUVIfMinus_ $ hs_getnameinfo ptr_addr addr_len ptr_h h_len ptr_s s_len cflag
    return (host, service)
  where
    addr_len = sizeOfSocketAddr addr
    h_len = if doHost then (# const NI_MAXHOST) else 0
    s_len = if doService then (# const NI_MAXSERV) else 0
    cflag = packBits nameInfoFlagMapping flags


-----------------------------------------------------------------------------
-- | Pack a list of values into a bitmask.  The possible mappings from
-- value to bit-to-set are given as the first argument.  We assume
-- that each value can cause exactly one bit to be set; unpackBits will
-- break if this property is not true.
--
packBits :: (Eq a, Num b, Bits b) => [(a, b)] -> [a] -> b
{-# INLINE packBits #-}
packBits mapping xs = List.foldl' go 0 mapping
  where
    go acc (k, v) | k `elem` xs = acc .|. v
                  | otherwise   = acc

-- | Unpack a bitmask into a list of values.
unpackBits :: (Num b, Bits b) => [(a, b)] -> b -> [a]
{-# INLINE unpackBits #-}
-- Be permissive and ignore unknown bit values. At least on OS X,
-- getaddrinfo returns an ai_flags field with bits set that have no
-- entry in <netdb.h>.
unpackBits [] _    = []
unpackBits ((k,v):xs) r
    | r .&. v /= 0 = k : unpackBits xs (r .&. complement v)
    | otherwise    = unpackBits xs r

-----------------------------------------------------------------------------
foreign import ccall safe "hs_getaddrinfo"
    hs_getaddrinfo :: Ptr Word8 -- ^ host 
                   -> Ptr Word8 -- ^ service
                   -> Ptr AddrInfo   -- ^ hints
                   -> Ptr (Ptr AddrInfo) -- ^ output addrinfo linked list
                   -> IO Int

foreign import ccall unsafe "freeaddrinfo" freeaddrinfo :: Ptr AddrInfo -> IO ()

foreign import ccall safe "hs_getnameinfo"
    hs_getnameinfo :: Ptr SocketAddr
                      -> CSize
                      -> CString -- ^ output host 
                      -> CSize
                      -> CString -- ^ output service
                      -> CSize
                      -> CInt    -- ^ flags
                      -> IO Int
