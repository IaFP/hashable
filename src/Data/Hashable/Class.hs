{-# LANGUAGE BangPatterns, CPP, MagicHash,
             ScopedTypeVariables, UnliftedFFITypes, DeriveDataTypeable,
             DefaultSignatures, FlexibleContexts, TypeFamilies, TypeOperators,
             QuantifiedConstraints,
             MultiParamTypeClasses, CApiFFI, PartialTypeConstructors, UndecidableInstances #-}

{-# LANGUAGE Trustworthy #-}

#if __GLASGOW_HASKELL__ >= 801
{-# LANGUAGE PolyKinds #-} -- For TypeRep instances
#endif

{-# OPTIONS_GHC -fno-warn-deprecations #-}

------------------------------------------------------------------------
-- |
-- Module      :  Data.Hashable.Class
-- Copyright   :  (c) Milan Straka 2010
--                (c) Johan Tibell 2011
--                (c) Bryan O'Sullivan 2011, 2012
-- SPDX-License-Identifier : BSD-3-Clause
-- Maintainer  :  johan.tibell@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
-- This module defines a class, 'Hashable', for types that can be
-- converted to a hash value.  This class exists for the benefit of
-- hashing-based data structures.  The module provides instances for
-- most standard types.

module Data.Hashable.Class
    (
      -- * Computing hash values
      Hashable(..)
    , Hashable1(..)
    , Hashable2(..)

      -- ** Support for generics
    , genericHashWithSalt
    , genericLiftHashWithSalt
    , GHashable(..)
    , HashArgs(..)
    , Zero
    , One

      -- * Creating new instances
    , hashUsing
    , hashPtr
    , hashPtrWithSalt
    , hashByteArray
    , hashByteArrayWithSalt
    , defaultHashWithSalt
      -- * Higher Rank Functions
    , hashWithSalt1
    , hashWithSalt2
    , defaultLiftHashWithSalt
    -- * Caching hashes
    , Hashed
    , hashed
    , hashedHash
    , unhashed
    , mapHashed
    , traverseHashed
    ) where

import Control.Applicative (Const(..))
import Control.Exception (assert)
import Control.DeepSeq (NFData(rnf))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Unsafe as B
import Data.Complex (Complex(..))
import Data.Int (Int8, Int16, Int32, Int64)
import Data.List (foldl')
import Data.Ratio (Ratio, denominator, numerator)
import qualified Data.Text as T
import qualified Data.Text.Array as TA
import qualified Data.Text.Internal as T
import qualified Data.Text.Lazy as TL
import Data.Version (Version(..))
import Data.Word (Word8, Word16, Word32, Word64)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr, FunPtr, IntPtr, WordPtr, castPtr, castFunPtrToPtr, ptrToIntPtr)
import Foreign.Storable (alignment, peek, sizeOf)
import GHC.Base (ByteArray#)
import GHC.Conc (ThreadId(..))
import GHC.Prim (ThreadId#)
import System.IO.Unsafe (unsafeDupablePerformIO)
import System.Mem.StableName
import Data.Unique (Unique, hashUnique)
import qualified Data.IntMap as IntMap
import qualified Data.IntSet as IntSet
import qualified Data.Map as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import qualified Data.Tree as Tree

-- As we use qualified F.Foldable, we don't get warnings with newer base
import qualified Data.Foldable as F

import GHC.Types (type(@), Total)

#if MIN_VERSION_base(4,7,0)
import Data.Proxy (Proxy)
#endif

#if MIN_VERSION_base(4,7,0)
import Data.Fixed (Fixed(..))
#else
import Data.Fixed (Fixed)
import Unsafe.Coerce (unsafeCoerce)
#endif

#if MIN_VERSION_base(4,8,0)
import Data.Functor.Identity (Identity(..))
#endif

import GHC.Generics

#if   MIN_VERSION_base(4,10,0)
import Type.Reflection (Typeable, TypeRep, SomeTypeRep(..))
import Type.Reflection.Unsafe (typeRepFingerprint)
import GHC.Fingerprint.Type(Fingerprint(..))
#elif MIN_VERSION_base(4,8,0)
import Data.Typeable (typeRepFingerprint, Typeable, TypeRep)
import GHC.Fingerprint.Type(Fingerprint(..))
#else
import Data.Typeable.Internal (Typeable, TypeRep (..))
import GHC.Fingerprint.Type(Fingerprint(..))
#endif

import Foreign.C.Types (CInt(..))

#if !(MIN_VERSION_base(4,8,0))
import Data.Word (Word)
#endif

#if !(MIN_VERSION_bytestring(0,10,0))
import qualified Data.ByteString.Lazy.Internal as BL  -- foldlChunks
#endif

#if MIN_VERSION_bytestring(0,10,4)
import qualified Data.ByteString.Short.Internal as BSI
#endif

#ifdef VERSION_ghc_bignum
import GHC.Num.BigNat (BigNat (..))
import GHC.Num.Integer (Integer (..))
import GHC.Num.Natural (Natural (..))
import GHC.Exts (Int (..), sizeofByteArray#)
#endif

#ifdef VERSION_integer_gmp

# if MIN_VERSION_integer_gmp(1,0,0)
#  define MIN_VERSION_integer_gmp_1_0_0
# endif

import GHC.Exts (Int(..))
import GHC.Integer.GMP.Internals (Integer(..))
# if defined(MIN_VERSION_integer_gmp_1_0_0)
import GHC.Exts (sizeofByteArray#)
import GHC.Integer.GMP.Internals (BigNat(BN#))
# endif
#endif

#if MIN_VERSION_base(4,8,0)
import Data.Void (Void, absurd)
import GHC.Exts (Word(..))
#ifndef VERSION_ghc_bignum
import GHC.Natural (Natural(..))
#endif
#endif

import Data.Functor.Classes (Eq1(..),Ord1(..),Show1(..))

-- Whether we have lifted classes, in particular, Eq2
#ifndef MIN_VERSION_transformers
#define LIFTED_FUNCTOR_CLASSES 1
#else
#if !(MIN_VERSION_transformers(0,4,0) && !MIN_VERSION_transformers(0,5,0))
#define LIFTED_FUNCTOR_CLASSES 1
#endif
#endif

#ifdef LIFTED_FUNCTOR_CLASSES
import Data.Functor.Classes (Eq2)
#endif

#if MIN_VERSION_base(4,9,0)
import qualified Data.List.NonEmpty as NE
import Data.Semigroup

import Data.Functor.Compose (Compose(..))
import qualified Data.Functor.Product as FP
import qualified Data.Functor.Sum as FS
#endif

#if MIN_VERSION_base(4,16,0)
import Data.Tuple (Solo (..))
#elif MIN_VERSION_base(4,15,0)
import GHC.Tuple (Solo (..))
#endif

import Data.String (IsString(..))

#if MIN_VERSION_base(4,9,0)
import Data.Kind (Type)
#else
#define Type *
#endif

import Data.Hashable.Imports
import Data.Hashable.LowLevel

#ifdef VERSION_base_orphans
import Data.Orphans ()
#endif

#ifdef VERSION_transformers_compat
import Control.Monad.Trans.Instances ()
#endif

#ifdef VERSION_ghc_bignum_orphans
import GHC.Num.Orphans ()
#endif

#ifdef VERSION_functor_classes_compat
import Data.Map.Functor.Classes ()
import Data.Set.Functor.Classes ()
import Data.IntMap.Functor.Classes ()
import Data.Sequence.Functor.Classes ()
import Data.Tree.Functor.Classes ()
#endif

#include "MachDeps.h"

infixl 0 `hashWithSalt`

------------------------------------------------------------------------
-- * Computing hash values

-- | The class of types that can be converted to a hash value.
--
-- Minimal implementation: 'hashWithSalt'.
--
-- /Note:/ the hash is not guaranteed to be stable across
-- library versions, operating systems or architectures.
-- For stable hashing use named hashes: SHA256, CRC32 etc.
--
-- If you are looking for 'Hashable' instance in @time@ package,
-- check [time-compat](https://hackage.haskell.org/package/time-compat)
--
class Eq a => Hashable a where
    -- | Return a hash value for the argument, using the given salt.
    --
    -- The general contract of 'hashWithSalt' is:
    --
    --  * If two values are equal according to the '==' method, then
    --    applying the 'hashWithSalt' method on each of the two values
    --    /must/ produce the same integer result if the same salt is
    --    used in each case.
    --
    --  * It is /not/ required that if two values are unequal
    --    according to the '==' method, then applying the
    --    'hashWithSalt' method on each of the two values must produce
    --    distinct integer results. However, the programmer should be
    --    aware that producing distinct integer results for unequal
    --    values may improve the performance of hashing-based data
    --    structures.
    --
    --  * This method can be used to compute different hash values for
    --    the same input by providing a different salt in each
    --    application of the method. This implies that any instance
    --    that defines 'hashWithSalt' /must/ make use of the salt in
    --    its implementation.
    --
    --  * 'hashWithSalt' may return negative 'Int' values.
    --
    hashWithSalt :: Int -> a -> Int

    -- | Like 'hashWithSalt', but no salt is used. The default
    -- implementation uses 'hashWithSalt' with some default salt.
    -- Instances might want to implement this method to provide a more
    -- efficient implementation than the default implementation.
    hash :: a -> Int
    hash = hashWithSalt defaultSalt

    default hashWithSalt :: (
      forall x. Rep a @ x,
      Generic a,
      GHashable Zero (Rep a)) => Int -> a -> Int
    hashWithSalt = genericHashWithSalt
    {-# INLINE hashWithSalt #-}

-- | Generic 'hashWithSalt'.
--
-- @since 1.3.0.0
genericHashWithSalt :: (
#if MIN_VERSION_base(4,16,0)
  forall x. Rep a @ x, -- need to do this as `Total (Rep a)` won't do.
#endif
  Generic a,
  GHashable Zero (Rep a)) => Int -> a -> Int
genericHashWithSalt = \salt -> ghashWithSalt HashArgs0 salt . from
{-# INLINE genericHashWithSalt #-}

data Zero
data One

data family HashArgs arity a :: Type
data instance HashArgs Zero a = HashArgs0
newtype instance HashArgs One  a = HashArgs1 (Int -> a -> Int)

#if MIN_VERSION_base(4,16,0)
type instance HashArgs @ a = ()
type instance HashArgs a @ b = ()
#endif

-- | The class of types that can be generically hashed.
class
#if MIN_VERSION_base(4,16,0)
   Total f =>
#endif
  GHashable arity f where
    ghashWithSalt :: HashArgs arity a -> Int -> f a -> Int

class (
#if MIN_VERSION_base(4,16,0)
    Total t,
#endif
  Eq1 t) => Hashable1 t where
    -- | Lift a hashing function through the type constructor.
    liftHashWithSalt :: (Int -> a -> Int) -> Int -> t a -> Int

    default liftHashWithSalt :: (
#if MIN_VERSION_base(4,16,0)
      forall x. Rep1 t @ x,
#endif
      Generic1 t,
      GHashable One (Rep1 t)) => (Int -> a -> Int) -> Int -> t a -> Int
    liftHashWithSalt = genericLiftHashWithSalt
    {-# INLINE liftHashWithSalt #-}

-- | Generic 'liftHashWithSalt'.
--
-- @since 1.3.0.0
genericLiftHashWithSalt :: (
#if MIN_VERSION_base(4,16,0)
  forall x. Rep1 t @ x,
#endif
  Generic1 t,
  GHashable One (Rep1 t)) => (Int -> a -> Int) -> Int -> t a -> Int
genericLiftHashWithSalt = \h salt -> ghashWithSalt (HashArgs1 h) salt . from1
{-# INLINE genericLiftHashWithSalt #-}

#if LIFTED_FUNCTOR_CLASSES
class Eq2 t => Hashable2 t where
#else
class Hashable2 t where
#endif
    -- | Lift a hashing function through the binary type constructor.
    liftHashWithSalt2 :: (Int -> a -> Int) -> (Int -> b -> Int) -> Int -> t a b -> Int

-- | Lift the 'hashWithSalt' function through the type constructor.
--
-- > hashWithSalt1 = liftHashWithSalt hashWithSalt
hashWithSalt1 :: (Hashable1 f, Hashable a) => Int -> f a -> Int
hashWithSalt1 = liftHashWithSalt hashWithSalt

-- | Lift the 'hashWithSalt' function through the type constructor.
--
-- > hashWithSalt2 = liftHashWithSalt2 hashWithSalt hashWithSalt
hashWithSalt2 :: (Hashable2 f, Hashable a, Hashable b) => Int -> f a b -> Int
hashWithSalt2 = liftHashWithSalt2 hashWithSalt hashWithSalt

-- | Lift the 'hashWithSalt' function halfway through the type constructor.
-- This function makes a suitable default implementation of 'liftHashWithSalt',
-- given that the type constructor @t@ in question can unify with @f a@.
defaultLiftHashWithSalt :: (Hashable2 f, Hashable a) => (Int -> b -> Int) -> Int -> f a b -> Int
defaultLiftHashWithSalt h = liftHashWithSalt2 hashWithSalt h

-- | Since we support a generic implementation of 'hashWithSalt' we
-- cannot also provide a default implementation for that method for
-- the non-generic instance use case. Instead we provide
-- 'defaultHashWith'.
defaultHashWithSalt :: Hashable a => Int -> a -> Int
defaultHashWithSalt salt x = salt `hashInt` hash x

-- | Transform a value into a 'Hashable' value, then hash the
-- transformed value using the given salt.
--
-- This is a useful shorthand in cases where a type can easily be
-- mapped to another type that is already an instance of 'Hashable'.
-- Example:
--
-- > data Foo = Foo | Bar
-- >          deriving (Enum)
-- >
-- > instance Hashable Foo where
-- >     hashWithSalt = hashUsing fromEnum
--
-- @since 1.2.0.0
hashUsing :: (Hashable b) =>
             (a -> b)           -- ^ Transformation function.
          -> Int                -- ^ Salt.
          -> a                  -- ^ Value to transform.
          -> Int
hashUsing f salt x = hashWithSalt salt (f x)
{-# INLINE hashUsing #-}

instance Hashable Int where
    hash = id
    hashWithSalt = hashInt

instance Hashable Int8 where
    hash = fromIntegral
    hashWithSalt = defaultHashWithSalt

instance Hashable Int16 where
    hash = fromIntegral
    hashWithSalt = defaultHashWithSalt

instance Hashable Int32 where
    hash = fromIntegral
    hashWithSalt = defaultHashWithSalt

instance Hashable Int64 where
    hash = fromIntegral
    hashWithSalt = hashInt64

instance Hashable Word where
    hash = fromIntegral
    hashWithSalt = defaultHashWithSalt

instance Hashable Word8 where
    hash = fromIntegral
    hashWithSalt = defaultHashWithSalt

instance Hashable Word16 where
    hash = fromIntegral
    hashWithSalt = defaultHashWithSalt

instance Hashable Word32 where
    hash = fromIntegral
    hashWithSalt = defaultHashWithSalt

instance Hashable Word64 where
    hashWithSalt = hashWord64

instance Hashable () where
    hash = fromEnum
    hashWithSalt = defaultHashWithSalt

instance Hashable Bool where
    hash = fromEnum
    hashWithSalt = defaultHashWithSalt

instance Hashable Ordering where
    hash = fromEnum
    hashWithSalt = defaultHashWithSalt

instance Hashable Char where
    hash = fromEnum
    hashWithSalt = defaultHashWithSalt

#if defined(MIN_VERSION_integer_gmp_1_0_0) || defined(VERSION_ghc_bignum)
instance Hashable BigNat where
    hashWithSalt salt (BN# ba) = hashByteArrayWithSalt ba 0 numBytes salt
                                 `hashWithSalt` size
      where
        size     = numBytes `quot` SIZEOF_HSWORD
        numBytes = I# (sizeofByteArray# ba)
#endif

#if MIN_VERSION_base(4,8,0)
instance Hashable Natural where
# if defined(VERSION_ghc_bignum)
    hash (NS n)   = hash (W# n)
    hash (NB bn)  = hash (BN# bn)

    hashWithSalt salt (NS n)  = hashWithSalt salt (W# n)
    hashWithSalt salt (NB bn) = hashWithSalt salt (BN# bn)
# else
# if defined(MIN_VERSION_integer_gmp_1_0_0)
    hash (NatS# n)   = hash (W# n)
    hash (NatJ# bn)  = hash bn

    hashWithSalt salt (NatS# n)   = hashWithSalt salt (W# n)
    hashWithSalt salt (NatJ# bn)  = hashWithSalt salt bn
# else
    hash (Natural n) = hash n

    hashWithSalt salt (Natural n) = hashWithSalt salt n
# endif
# endif
#endif

instance Hashable Integer where
#if defined(VERSION_ghc_bignum)
    hash (IS n)  = I# n
    hash (IP bn) = hash (BN# bn)
    hash (IN bn) = negate (hash (BN# bn))

    hashWithSalt salt (IS n)  = hashWithSalt salt (I# n)
    hashWithSalt salt (IP bn) = hashWithSalt salt (BN# bn)
    hashWithSalt salt (IN bn) = negate (hashWithSalt salt (BN# bn))
#else
#if defined(VERSION_integer_gmp)
# if defined(MIN_VERSION_integer_gmp_1_0_0)
    hash (S# n)   = (I# n)
    hash (Jp# bn) = hash bn
    hash (Jn# bn) = negate (hash bn)

    hashWithSalt salt (S# n)   = hashWithSalt salt (I# n)
    hashWithSalt salt (Jp# bn) = hashWithSalt salt bn
    hashWithSalt salt (Jn# bn) = negate (hashWithSalt salt bn)
# else
    hash (S# int) = I# int
    hash n@(J# size# byteArray)
        | n >= minInt && n <= maxInt = fromInteger n :: Int
        | otherwise = let size = I# size#
                          numBytes = SIZEOF_HSWORD * abs size
                      in hashByteArrayWithSalt byteArray 0 numBytes defaultSalt
                         `hashWithSalt` size
      where minInt = fromIntegral (minBound :: Int)
            maxInt = fromIntegral (maxBound :: Int)

    hashWithSalt salt (S# n) = hashWithSalt salt (I# n)
    hashWithSalt salt n@(J# size# byteArray)
        | n >= minInt && n <= maxInt = hashWithSalt salt (fromInteger n :: Int)
        | otherwise = let size = I# size#
                          numBytes = SIZEOF_HSWORD * abs size
                      in hashByteArrayWithSalt byteArray 0 numBytes salt
                         `hashWithSalt` size
      where minInt = fromIntegral (minBound :: Int)
            maxInt = fromIntegral (maxBound :: Int)
# endif
#else
    hashWithSalt salt = foldl' hashWithSalt salt . go
      where
        go n | inBounds n = [fromIntegral n :: Int]
             | otherwise   = fromIntegral n : go (n `shiftR` WORD_SIZE_IN_BITS)
        maxInt = fromIntegral (maxBound :: Int)
        inBounds x = x >= fromIntegral (minBound :: Int) && x <= maxInt
#endif
#endif

instance Hashable a => Hashable (Complex a) where
    {-# SPECIALIZE instance Hashable (Complex Double) #-}
    {-# SPECIALIZE instance Hashable (Complex Float)  #-}
    hash (r :+ i) = hash r `hashWithSalt` i
    hashWithSalt = hashWithSalt1
instance Hashable1 Complex where
    liftHashWithSalt h s (r :+ i) = s `h` r `h` i

#if MIN_VERSION_base(4,9,0)
-- Starting with base-4.9, numerator/denominator don't need 'Integral' anymore
instance Hashable a => Hashable (Ratio a) where
#else
instance (Integral a, Hashable a) => Hashable (Ratio a) where
#endif
    {-# SPECIALIZE instance Hashable (Ratio Integer) #-}
    hash a = hash (numerator a) `hashWithSalt` denominator a
    hashWithSalt s a = s `hashWithSalt` numerator a `hashWithSalt` denominator a

-- | __Note__: prior to @hashable-1.3.0.0@, @hash 0.0 /= hash (-0.0)@
--
-- The 'hash' of NaN is not well defined.
--
-- @since 1.3.0.0
instance Hashable Float where
    hash x
        | x == -0.0 || x == 0.0 = 0 -- see note in 'Hashable Double'
        | isIEEE x =
            assert (sizeOf x >= sizeOf (0::Word32) &&
                    alignment x >= alignment (0::Word32)) $
            hash ((unsafeDupablePerformIO $ with x $ peek . castPtr) :: Word32)
        | otherwise = hash (show x)
    hashWithSalt = defaultHashWithSalt

-- | __Note__: prior to @hashable-1.3.0.0@, @hash 0.0 /= hash (-0.0)@
--
-- The 'hash' of NaN is not well defined.
--
-- @since 1.3.0.0
instance Hashable Double where
    hash x
        | x == -0.0 || x == 0.0 = 0 -- s.t. @hash -0.0 == hash 0.0@ ; see #173
        | isIEEE x =
            assert (sizeOf x >= sizeOf (0::Word64) &&
                    alignment x >= alignment (0::Word64)) $
            hash ((unsafeDupablePerformIO $ with x $ peek . castPtr) :: Word64)
        | otherwise = hash (show x)
    hashWithSalt = defaultHashWithSalt

-- | A value with bit pattern (01)* (or 5* in hexa), for any size of Int.
-- It is used as data constructor distinguisher. GHC computes its value during
-- compilation.
distinguisher :: Int
distinguisher = fromIntegral $ (maxBound :: Word) `quot` 3
{-# INLINE distinguisher #-}

instance Hashable a => Hashable (Maybe a) where
    hash Nothing = 0
    hash (Just a) = distinguisher `hashWithSalt` a
    hashWithSalt = hashWithSalt1

instance Hashable1 Maybe where
    liftHashWithSalt _ s Nothing = s `hashInt` 0
    liftHashWithSalt h s (Just a) = s `hashInt` distinguisher `h` a

instance (Hashable a, Hashable b) => Hashable (Either a b) where
    hash (Left a)  = 0 `hashWithSalt` a
    hash (Right b) = distinguisher `hashWithSalt` b
    hashWithSalt = hashWithSalt1

instance Hashable a => Hashable1 (Either a) where
    liftHashWithSalt = defaultLiftHashWithSalt

instance Hashable2 Either where
    liftHashWithSalt2 h _ s (Left a) = s `hashInt` 0 `h` a
    liftHashWithSalt2 _ h s (Right b) = s `hashInt` distinguisher `h` b

instance (Hashable a1, Hashable a2) => Hashable (a1, a2) where
    hash (a1, a2) = hash a1 `hashWithSalt` a2
    hashWithSalt = hashWithSalt1

instance Hashable a1 => Hashable1 ((,) a1) where
    liftHashWithSalt = defaultLiftHashWithSalt

instance Hashable2 (,) where
    liftHashWithSalt2 h1 h2 s (a1, a2) = s `h1` a1 `h2` a2

instance (Hashable a1, Hashable a2, Hashable a3) => Hashable (a1, a2, a3) where
    hash (a1, a2, a3) = hash a1 `hashWithSalt` a2 `hashWithSalt` a3
    hashWithSalt = hashWithSalt1

instance (Hashable a1, Hashable a2) => Hashable1 ((,,) a1 a2) where
    liftHashWithSalt = defaultLiftHashWithSalt

instance Hashable a1 => Hashable2 ((,,) a1) where
    liftHashWithSalt2 h1 h2 s (a1, a2, a3) =
      (s `hashWithSalt` a1) `h1` a2 `h2` a3

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4) =>
         Hashable (a1, a2, a3, a4) where
    hash (a1, a2, a3, a4) = hash a1 `hashWithSalt` a2
                            `hashWithSalt` a3 `hashWithSalt` a4
    hashWithSalt = hashWithSalt1

instance (Hashable a1, Hashable a2, Hashable a3) => Hashable1 ((,,,) a1 a2 a3) where
    liftHashWithSalt = defaultLiftHashWithSalt

instance (Hashable a1, Hashable a2) => Hashable2 ((,,,) a1 a2) where
    liftHashWithSalt2 h1 h2 s (a1, a2, a3, a4) =
      (s `hashWithSalt` a1 `hashWithSalt` a2) `h1` a3 `h2` a4

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5)
      => Hashable (a1, a2, a3, a4, a5) where
    hash (a1, a2, a3, a4, a5) =
        hash a1 `hashWithSalt` a2 `hashWithSalt` a3
        `hashWithSalt` a4 `hashWithSalt` a5
    hashWithSalt s (a1, a2, a3, a4, a5) =
        s `hashWithSalt` a1 `hashWithSalt` a2 `hashWithSalt` a3
        `hashWithSalt` a4 `hashWithSalt` a5

{-
instance (Hashable a1, Hashable a2, Hashable a3,
          Hashable a4) => Hashable1 ((,,,,) a1 a2 a3 a4) where
    liftHashWithSalt = defaultLiftHashWithSalt

instance (Hashable a1, Hashable a2, Hashable a3)
      => Hashable2 ((,,,,) a1 a2 a3) where
    liftHashWithSalt2 h1 h2 s (a1, a2, a3, a4, a5) =
      (s `hashWithSalt` a1 `hashWithSalt` a2
         `hashWithSalt` a3) `h1` a4 `h2` a5
-}

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5,
          Hashable a6) => Hashable (a1, a2, a3, a4, a5, a6) where
    hash (a1, a2, a3, a4, a5, a6) =
        hash a1 `hashWithSalt` a2 `hashWithSalt` a3
        `hashWithSalt` a4 `hashWithSalt` a5 `hashWithSalt` a6
    hashWithSalt s (a1, a2, a3, a4, a5, a6) =
        s `hashWithSalt` a1 `hashWithSalt` a2 `hashWithSalt` a3
        `hashWithSalt` a4 `hashWithSalt` a5 `hashWithSalt` a6

{-
instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4,
          Hashable a5) => Hashable1 ((,,,,,) a1 a2 a3 a4 a5) where
    liftHashWithSalt = defaultLiftHashWithSalt

instance (Hashable a1, Hashable a2, Hashable a3,
          Hashable a4) => Hashable2 ((,,,,,) a1 a2 a3 a4) where
    liftHashWithSalt2 h1 h2 s (a1, a2, a3, a4, a5, a6) =
      (s `hashWithSalt` a1 `hashWithSalt` a2 `hashWithSalt` a3
         `hashWithSalt` a4) `h1` a5 `h2` a6
-}

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5,
          Hashable a6, Hashable a7) =>
         Hashable (a1, a2, a3, a4, a5, a6, a7) where
    hash (a1, a2, a3, a4, a5, a6, a7) =
        hash a1 `hashWithSalt` a2 `hashWithSalt` a3
        `hashWithSalt` a4 `hashWithSalt` a5 `hashWithSalt` a6 `hashWithSalt` a7
    hashWithSalt s (a1, a2, a3, a4, a5, a6, a7) =
        s `hashWithSalt` a1 `hashWithSalt` a2 `hashWithSalt` a3
        `hashWithSalt` a4 `hashWithSalt` a5 `hashWithSalt` a6 `hashWithSalt` a7

{-
instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4, Hashable a5, Hashable a6) => Hashable1 ((,,,,,,) a1 a2 a3 a4 a5 a6) where
    liftHashWithSalt = defaultLiftHashWithSalt

instance (Hashable a1, Hashable a2, Hashable a3, Hashable a4,
          Hashable a5) => Hashable2 ((,,,,,,) a1 a2 a3 a4 a5) where
    liftHashWithSalt2 h1 h2 s (a1, a2, a3, a4, a5, a6, a7) =
      (s `hashWithSalt` a1 `hashWithSalt` a2 `hashWithSalt` a3
         `hashWithSalt` a4 `hashWithSalt` a5) `h1` a6 `h2` a7
-}

instance Hashable (StableName a) where
    hash = hashStableName
    hashWithSalt = defaultHashWithSalt

-- Auxiliary type for Hashable [a] definition
data SPInt = SP !Int !Int

instance Hashable a => Hashable [a] where
    {-# SPECIALIZE instance Hashable [Char] #-}
    hashWithSalt = hashWithSalt1

instance Hashable1 [] where
    liftHashWithSalt h salt arr = finalise (foldl' step (SP salt 0) arr)
      where
        finalise (SP s l) = hashWithSalt s l
        step (SP s l) x   = SP (h s x) (l + 1)

instance Hashable B.ByteString where
    hashWithSalt salt bs = unsafeDupablePerformIO $
                           B.unsafeUseAsCStringLen bs $ \(p, len) ->
                           hashPtrWithSalt p (fromIntegral len) (hashWithSalt salt len)

instance Hashable BL.ByteString where
    hashWithSalt salt = finalise . BL.foldlChunks step (SP salt 0)
      where
        finalise (SP s l) = hashWithSalt s l
        step (SP s l) bs  = unsafeDupablePerformIO $
                            B.unsafeUseAsCStringLen bs $ \(p, len) -> do
                                s' <- hashPtrWithSalt p (fromIntegral len) s
                                return (SP s' (l + len))

#if MIN_VERSION_bytestring(0,10,4)
instance Hashable BSI.ShortByteString where
    hashWithSalt salt sbs@(BSI.SBS ba) =
        hashByteArrayWithSalt ba 0 (BSI.length sbs) (hashWithSalt salt (BSI.length sbs))
#endif

#if MIN_VERSION_text(2,0,0)

instance Hashable T.Text where
    hashWithSalt salt (T.Text (TA.ByteArray arr) off len) =
        hashByteArrayWithSalt arr off len (hashWithSalt salt len)

instance Hashable TL.Text where
    hashWithSalt salt = finalise . TL.foldlChunks step (SP salt 0)
      where
        finalise (SP s l) = hashWithSalt s l
        step (SP s l) (T.Text (TA.ByteArray arr) off len) = SP
            (hashByteArrayWithSalt arr off len s)
            (l + len)

#else

instance Hashable T.Text where
    hashWithSalt salt (T.Text arr off len) =
        hashByteArrayWithSalt (TA.aBA arr) (off `shiftL` 1) (len `shiftL` 1)
        (hashWithSalt salt len)

instance Hashable TL.Text where
    hashWithSalt salt = finalise . TL.foldlChunks step (SP salt 0)
      where
        finalise (SP s l) = hashWithSalt s l
        step (SP s l) (T.Text arr off len) = SP
            (hashByteArrayWithSalt (TA.aBA arr) (off `shiftL` 1) (len `shiftL` 1) s)
            (l + len)

#endif

-- | Compute the hash of a ThreadId.
hashThreadId :: ThreadId -> Int
hashThreadId (ThreadId t) = hash (fromIntegral (getThreadId t) :: Int)

-- this cannot be capi, as GHC panics.
foreign import ccall unsafe "rts_getThreadId" getThreadId
    :: ThreadId# -> CInt

instance Hashable ThreadId where
    hash = hashThreadId
    hashWithSalt = defaultHashWithSalt

instance Hashable (Ptr a) where
    hashWithSalt salt p = hashWithSalt salt $ ptrToIntPtr p

instance Hashable (FunPtr a) where
    hashWithSalt salt p = hashWithSalt salt $ castFunPtrToPtr p

instance Hashable IntPtr where
    hash n = fromIntegral n
    hashWithSalt = defaultHashWithSalt

instance Hashable WordPtr where
    hash n = fromIntegral n
    hashWithSalt = defaultHashWithSalt

----------------------------------------------------------------------------
-- Fingerprint & TypeRep instances

-- | @since 1.3.0.0
instance Hashable Fingerprint where
    hash (Fingerprint x _) = fromIntegral x
    hashWithSalt = defaultHashWithSalt
    {-# INLINE hash #-}

#if MIN_VERSION_base(4,10,0)

hashTypeRep :: Type.Reflection.TypeRep a -> Int
hashTypeRep tr =
    let Fingerprint x _ = typeRepFingerprint tr in fromIntegral x

instance Hashable Type.Reflection.SomeTypeRep where
    hash (Type.Reflection.SomeTypeRep r) = hashTypeRep r
    hashWithSalt = defaultHashWithSalt
    {-# INLINE hash #-}

instance Hashable (Type.Reflection.TypeRep a) where
    hash = hashTypeRep
    hashWithSalt = defaultHashWithSalt
    {-# INLINE hash #-}

#else

-- | Compute the hash of a TypeRep, in various GHC versions we can do this quickly.
hashTypeRep :: TypeRep -> Int
{-# INLINE hashTypeRep #-}
#if   MIN_VERSION_base(4,8,0)
-- Fingerprint is just the MD5, so taking any Int from it is fine
hashTypeRep tr = let Fingerprint x _ = typeRepFingerprint tr in fromIntegral x
#else
-- Fingerprint is just the MD5, so taking any Int from it is fine
hashTypeRep (TypeRep (Fingerprint x _) _ _) = fromIntegral x
#endif

instance Hashable TypeRep where
    hash = hashTypeRep
    hashWithSalt = defaultHashWithSalt
    {-# INLINE hash #-}

#endif

----------------------------------------------------------------------------

#if MIN_VERSION_base(4,8,0)
instance Hashable Void where
    hashWithSalt _ = absurd
#endif

-- | Compute a hash value for the content of this pointer.
hashPtr :: Ptr a      -- ^ pointer to the data to hash
        -> Int        -- ^ length, in bytes
        -> IO Int     -- ^ hash value
hashPtr p len = hashPtrWithSalt p len defaultSalt

-- | Compute a hash value for the content of this 'ByteArray#',
-- beginning at the specified offset, using specified number of bytes.
hashByteArray :: ByteArray#  -- ^ data to hash
              -> Int         -- ^ offset, in bytes
              -> Int         -- ^ length, in bytes
              -> Int         -- ^ hash value
hashByteArray ba0 off len = hashByteArrayWithSalt ba0 off len defaultSalt
{-# INLINE hashByteArray #-}

instance Hashable Unique where
    hash = hashUnique
    hashWithSalt = defaultHashWithSalt

instance Hashable Version where
    hashWithSalt salt (Version branch tags) =
        salt `hashWithSalt` branch `hashWithSalt` tags

#if MIN_VERSION_base(4,7,0)
instance Hashable (Fixed a) where
    hashWithSalt salt (MkFixed i) = hashWithSalt salt i
#else
instance Hashable (Fixed a) where
    hashWithSalt salt x = hashWithSalt salt (unsafeCoerce x :: Integer)
#endif


#if MIN_VERSION_base(4,8,0)
-- TODO: make available on all base
instance Hashable a => Hashable (Identity a) where
    hashWithSalt = hashWithSalt1
instance Hashable1 Identity where
    liftHashWithSalt h salt (Identity x) = h salt x
#endif

-- Using hashWithSalt1 would cause needless constraint
instance Hashable a => Hashable (Const a b) where
    hashWithSalt salt (Const x) = hashWithSalt salt x

instance Hashable a => Hashable1 (Const a) where
    liftHashWithSalt = defaultLiftHashWithSalt

instance Hashable2 Const where
    liftHashWithSalt2 f _ salt (Const x) = f salt x

#if MIN_VERSION_base(4,7,0)
instance Hashable (Proxy a) where
    hash _ = 0
    hashWithSalt s _ = s

instance Hashable1 Proxy where
    liftHashWithSalt _ s _ = s
#endif

-- instances formerly provided by 'semigroups' package
#if MIN_VERSION_base(4,9,0)
instance Hashable a => Hashable (NE.NonEmpty a) where
    hashWithSalt p (a NE.:| as) = p `hashWithSalt` a `hashWithSalt` as

-- | @since 1.3.1.0
instance Hashable1 NE.NonEmpty where
    liftHashWithSalt h salt (a NE.:| as) = liftHashWithSalt h (h salt a) as

instance Hashable a => Hashable (Min a) where
    hashWithSalt p (Min a) = hashWithSalt p a

instance Hashable a => Hashable (Max a) where
    hashWithSalt p (Max a) = hashWithSalt p a

-- | __Note__: Prior to @hashable-1.3.0.0@ the hash computation included the second argument of 'Arg' which wasn't consistent with its 'Eq' instance.
--
-- @since 1.3.0.0
instance Hashable a => Hashable (Arg a b) where
    hashWithSalt p (Arg a _) = hashWithSalt p a

instance Hashable a => Hashable (First a) where
    hashWithSalt p (First a) = hashWithSalt p a


instance Hashable a => Hashable (Last a) where
    hashWithSalt p (Last a) = hashWithSalt p a


instance Hashable a => Hashable (WrappedMonoid a) where
    hashWithSalt p (WrapMonoid a) = hashWithSalt p a


#if !MIN_VERSION_base(4,16,0)
instance Hashable a => Hashable (Option a) where
    hashWithSalt p (Option a) = hashWithSalt p a

#endif

-- TODO: this instance is removed as there isn't Eq1 Min/Max, ...

#if 0
-- | @since 1.3.1.0
-- instance Hashable1 Min where liftHashWithSalt h salt (Min a) = h salt a

-- | @since 1.3.1.0
-- instance Hashable1 Max where liftHashWithSalt h salt (Max a) = h salt a

-- | @since 1.3.1.0
-- instance Hashable1 First where liftHashWithSalt h salt (First a) = h salt a

-- | @since 1.3.1.0
-- instance Hashable1 Last where liftHashWithSalt h salt (Last a) = h salt a


-- | @since 1.3.1.0
-- instance Hashable1 WrappedMonoid where liftHashWithSalt h salt (WrapMonoid a) = h salt a

-- | @since 1.3.1.0
-- instance Hashable1 Option where liftHashWithSalt h salt (Option a) = liftHashWithSalt h salt a
#endif
#endif

-- instances for @Data.Functor.{Product,Sum,Compose}@, present
-- in base-4.9 and onward.
#if MIN_VERSION_base(4,9,0)

-- | In general, @hash (Compose x) ≠ hash x@. However, @hashWithSalt@ satisfies
-- its variant of this equivalence.
instance (Hashable1 f, Hashable1 g, Hashable a) => Hashable (Compose f g a) where
    hashWithSalt = hashWithSalt1

instance (Hashable1 f, Hashable1 g) => Hashable1 (Compose f g) where
    liftHashWithSalt h s = liftHashWithSalt (liftHashWithSalt h) s . getCompose

instance (Hashable1 f, Hashable1 g) => Hashable1 (FP.Product f g) where
    liftHashWithSalt h s (FP.Pair a b) = liftHashWithSalt h (liftHashWithSalt h s a) b

instance (Hashable1 f, Hashable1 g, Hashable a) => Hashable (FP.Product f g a) where
    hashWithSalt = hashWithSalt1

instance (Hashable1 f, Hashable1 g) => Hashable1 (FS.Sum f g) where
    liftHashWithSalt h s (FS.InL a) = liftHashWithSalt h (s `hashInt` 0) a
    liftHashWithSalt h s (FS.InR a) = liftHashWithSalt h (s `hashInt` distinguisher) a

instance (Hashable1 f, Hashable1 g, Hashable a) => Hashable (FS.Sum f g a) where
    hashWithSalt = hashWithSalt1
#endif

-- | A hashable value along with the result of the 'hash' function.
data Hashed a = Hashed a {-# UNPACK #-} !Int
  deriving (Typeable)

-- | Wrap a hashable value, caching the 'hash' function result.
hashed :: Hashable a => a -> Hashed a
hashed a = Hashed a (hash a)

-- | Unwrap hashed value.
unhashed :: Hashed a -> a
unhashed (Hashed a _) = a

-- | 'hash' has 'Eq' requirement.
--
-- @since 1.4.0.0
hashedHash :: Hashed a -> Int
hashedHash (Hashed _ h) = h

-- | Uses precomputed hash to detect inequality faster
instance Eq a => Eq (Hashed a) where
  Hashed a ha == Hashed b hb = ha == hb && a == b

instance Ord a => Ord (Hashed a) where
  Hashed a _ `compare` Hashed b _ = a `compare` b

instance Show a => Show (Hashed a) where
  showsPrec d (Hashed a _) = showParen (d > 10) $
    showString "hashed" . showChar ' ' . showsPrec 11 a

instance Eq a => Hashable (Hashed a) where
  hashWithSalt = defaultHashWithSalt
  hash = hashedHash


-- This instance is a little unsettling. It is unusal for
-- 'liftHashWithSalt' to ignore its first argument when a
-- value is actually available for it to work on.
instance Hashable1 Hashed where
  liftHashWithSalt _ s (Hashed _ h) = defaultHashWithSalt s h

instance (IsString a, Hashable a) => IsString (Hashed a) where
  fromString s = let r = fromString s in Hashed r (hash r)

instance F.Foldable Hashed where
  foldr f acc (Hashed a _) = f a acc

instance NFData a => NFData (Hashed a) where
  rnf = rnf . unhashed

-- | 'Hashed' cannot be 'Functor'
mapHashed :: Hashable b => (a -> b) -> Hashed a -> Hashed b
mapHashed f (Hashed a _) = hashed (f a)

-- | 'Hashed' cannot be 'Traversable'
traverseHashed :: (Hashable b, Functor f) => (a -> f b) -> Hashed a -> f (Hashed b)
traverseHashed f (Hashed a _) = fmap hashed (f a)

#if MIN_VERSION_base(4,9,0)
#define LIFTED_FUNCTOR_CLASSES 1
#elif defined(MIN_VERSION_transformers)
#if !(MIN_VERSION_transformers(0,4,0)) || MIN_VERSION_transformers(0,5,0)
#define LIFTED_FUNCTOR_CLASSES 1
#endif
#endif

-- instances for @Data.Functor.Classes@ higher rank typeclasses
-- in base-4.9 and onward.
#if LIFTED_FUNCTOR_CLASSES
instance Eq1 Hashed where
  liftEq f (Hashed a ha) (Hashed b hb) = ha == hb && f a b

instance Ord1 Hashed where
  liftCompare f (Hashed a _) (Hashed b _) = f a b

instance Show1 Hashed where
  liftShowsPrec sp _ d (Hashed a _) = showParen (d > 10) $
    showString "hashed " . sp 11 a
#else
instance Eq1 Hashed where eq1 = (==)
instance Ord1 Hashed where compare1 = compare
instance Show1 Hashed where showsPrec1 = showsPrec
#endif

-------------------------------------------------------------------------------
-- containers
-------------------------------------------------------------------------------

-- | @since 1.3.4.0
instance Hashable2 Map.Map where
    liftHashWithSalt2 hk hv s m = Map.foldlWithKey'
        (\s' k v -> hv (hk s' k) v)
        (hashWithSalt s (Map.size m))
        m

-- | @since 1.3.4.0
instance Hashable k => Hashable1 (Map.Map k) where
    liftHashWithSalt h s m = Map.foldlWithKey'
        (\s' k v -> h (hashWithSalt s' k) v)
        (hashWithSalt s (Map.size m))
        m

-- | @since 1.3.4.0
instance (Hashable k, Hashable v) => Hashable (Map.Map k v) where
    hashWithSalt = hashWithSalt2

-- | @since 1.3.4.0
instance Hashable1 IntMap.IntMap where
    liftHashWithSalt h s m = IntMap.foldlWithKey'
        (\s' k v -> h (hashWithSalt s' k) v)
        (hashWithSalt s (IntMap.size m))
        m

-- | @since 1.3.4.0
instance Hashable v => Hashable (IntMap.IntMap v) where
    hashWithSalt = hashWithSalt1

-- | @since 1.3.4.0
instance Hashable1 Set.Set where
    liftHashWithSalt h s x = Set.foldl' h (hashWithSalt s (Set.size x)) x

-- | @since 1.3.4.0
instance Hashable v => Hashable (Set.Set v) where
    hashWithSalt = hashWithSalt1

-- | @since 1.3.4.0
instance Hashable IntSet.IntSet where
    hashWithSalt salt x = IntSet.foldl' hashWithSalt
        (hashWithSalt salt (IntSet.size x))
        x

-- | @since 1.3.4.0
instance Hashable1 Seq.Seq where
    liftHashWithSalt h s x = F.foldl' h (hashWithSalt s (Seq.length x)) x

-- | @since 1.3.4.0
instance Hashable v => Hashable (Seq.Seq v) where
    hashWithSalt = hashWithSalt1

-- | @since 1.3.4.0
instance Hashable1 Tree.Tree where
    liftHashWithSalt h = go where
        go s (Tree.Node x xs) = liftHashWithSalt go (h s x) xs

-- | @since 1.3.4.0
instance Hashable v => Hashable (Tree.Tree v) where
    hashWithSalt = hashWithSalt1

-------------------------------------------------------------------------------
-- Solo
-------------------------------------------------------------------------------

#if MIN_VERSION_base(4,15,0)
instance Hashable a => Hashable (Solo a) where
    hashWithSalt = hashWithSalt1
instance Hashable1 Solo where
    liftHashWithSalt h salt (Solo x) = h salt x
#endif
