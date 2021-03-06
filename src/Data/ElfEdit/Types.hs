{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE Trustworthy #-} -- Cannot be Safe due to GeneralizedNewtypeDeriving
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE CPP #-}
#if __GLASGOW_HASKELL >= 800
{-# OPTIONS_GHC -fno-warn-missing-pattern-synonym-signatures #-}
#endif
module Data.ElfEdit.Types
  ( -- * Top level declarations
    Elf(..)
  , emptyElf
  , elfFileData
    -- ** ElfClass
  , ElfClass(..)
  , fromElfClass
  , SomeElfClass(..)
  , toSomeElfClass
  , elfClassInstances
  , elfClassByteWidth
  , elfClassBitWidth
  , ElfWordType
  , ElfWidthConstraints
    -- **  ElfData
  , ElfData(..)
  , fromElfData
  , toElfData
    -- * ElfHeader
  , ElfHeader(..)
  , elfHeader
  , expectedElfVersion
    -- * ElfDataRegion
  , ElfDataRegion(..)
  , asumDataRegions
  , ppRegion
  , module Data.ElfEdit.Sections
    -- ** ElfGOT
  , ElfGOT(..)
  , elfGotSize
  , elfGotSection
  , elfGotSectionFlags
    -- ** Symbol Table
  , ElfSymbolTable(..)
  , ElfSymbolTableEntry(..)
  , infoToTypeAndBind
  , typeAndBindToInfo
    --  * Memory size
  , ElfMemSize(..)
    -- * ElfSegment
  , ElfSegment(..)
  , SegmentIndex
  , ppSegment
    -- ** Elf segment type
  , ElfSegmentType(..)
  , pattern PT_NULL
  , pattern PT_LOAD
  , pattern PT_DYNAMIC
  , pattern PT_INTERP
  , pattern PT_NOTE
  , pattern PT_SHLIB
  , pattern PT_PHDR
  , pattern PT_TLS
  , pattern PT_NUM
  , pattern PT_LOOS
  , pattern PT_GNU_EH_FRAME
  , pattern PT_GNU_STACK
  , pattern PT_GNU_RELRO
  , pattern PT_PAX_FLAGS
  , pattern PT_HIOS
  , pattern PT_LOPROC
  , pattern PT_HIPROC
    -- ** Elf segment flags
  , ElfSegmentFlags(..)
  , pf_none, pf_x, pf_w, pf_r
    -- * GNU-specific extensions
  , GnuStack(..)
  , GnuRelroRegion(..)
    -- * Range
  , Range
  , inRange
  , slice
  , sliceL
    -- * Utilities
  , hasPermissions
  , ppHex
  ) where

import           Control.Applicative
import           Control.Lens hiding (enum)
import           Data.Bits
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import qualified Data.Foldable as F
import qualified Data.Map as Map
import qualified Data.Sequence as Seq
import qualified Data.Vector as V
import           Data.Word
import           GHC.TypeLits
import           Numeric (showHex)
import           Text.PrettyPrint.ANSI.Leijen hiding ((<>), (<$>))

import           Data.ElfEdit.Enums
import           Data.ElfEdit.Sections
import           Data.ElfEdit.SymbolEnums
import           Data.ElfEdit.Utils (showFlags)

-- | @p `hasPermissions` req@ returns true if all bits set in 'req' are set in 'p'.
hasPermissions :: Bits b => b -> b -> Bool
hasPermissions p req = (p .&. req) == req
{-# INLINE hasPermissions #-}

------------------------------------------------------------------------
-- Range

-- | A range contains a starting index and a byte count.
type Range w = (w,w)

inRange :: (Ord w, Num w) => w -> Range w -> Bool
inRange w (s,c) = s <= w && (w-s) < c

slice :: Integral w => Range w -> B.ByteString -> B.ByteString
slice (i,c) = B.take (fromIntegral c) . B.drop (fromIntegral i)

sliceL :: Integral w => Range w -> L.ByteString -> L.ByteString
sliceL (i,c) = L.take (fromIntegral c) . L.drop (fromIntegral i)

------------------------------------------------------------------------
-- Utilities

ppShow :: Show v => v -> Doc
ppShow = text . show

ppHex :: (Bits a, Integral a, Show a) => a -> String
ppHex v | v >= 0 = "0x" ++ fixLength (bitSizeMaybe v) (showHex v "")
        | otherwise = error "ppHex given negative value"
  where fixLength (Just n) s | r == 0 && w > l = replicate (w - l) '0' ++ s
          where (w,r) = n `quotRem` 4
                l = length s
        fixLength _ s = s

------------------------------------------------------------------------
-- ElfClass

-- | A flag indicating whether Elf is 32 or 64-bit.
data ElfClass (w :: Nat) where
  ELFCLASS32 :: ElfClass 32
  ELFCLASS64 :: ElfClass 64

instance Show (ElfClass w) where
  show ELFCLASS32 = "ELFCLASS32"
  show ELFCLASS64 = "ELFCLASS64"

-- | A flag indicating this is either 32 or 64 bit.
data SomeElfClass = forall w . SomeElfClass !(ElfClass w)

fromElfClass :: ElfClass w -> Word8
fromElfClass ELFCLASS32 = 1
fromElfClass ELFCLASS64 = 2

toSomeElfClass :: Word8 -> Maybe SomeElfClass
toSomeElfClass 1 = Just (SomeElfClass ELFCLASS32)
toSomeElfClass 2 = Just (SomeElfClass ELFCLASS64)
toSomeElfClass _ = Nothing

-- | An unsigned value of a given width
type family ElfWordType (w::Nat) :: * where
  ElfWordType 32 = Word32
  ElfWordType 64 = Word64

type ElfWidthConstraints w = (Bits (ElfWordType w), Integral (ElfWordType w), Show (ElfWordType w), Bounded (ElfWordType w))

-- | Given a provides a way to access 'Bits', 'Integral' and 'Show' instances
-- of underlying word types associated with an 'ElfClass'.
elfClassInstances :: ElfClass w
                  -> (ElfWidthConstraints w => a)
                  -> a
elfClassInstances ELFCLASS32 a = a
elfClassInstances ELFCLASS64 a = a

-- | Return the number of bytes in an address with this elf class.
elfClassByteWidth :: ElfClass w -> Int
elfClassByteWidth ELFCLASS32 = 4
elfClassByteWidth ELFCLASS64 = 8

-- | Return the number of bits in an address with this elf class.
elfClassBitWidth :: ElfClass w -> Int
elfClassBitWidth ELFCLASS32 = 32
elfClassBitWidth ELFCLASS64 = 64

-- | Return the width of an elf word.
type family ElfWordWidth (w :: *) :: Nat where
  ElfWordWidth Word32 = 32
  ElfWordWidth Word64 = 64


------------------------------------------------------------------------
-- ElfData

-- | A flag indicating byte order used to encode data.
data ElfData = ELFDATA2LSB -- ^ Least significant byte first
             | ELFDATA2MSB -- ^ Most significant byte first.
  deriving (Eq, Ord, Show)

toElfData :: Word8 -> Maybe ElfData
toElfData 1 = Just $ ELFDATA2LSB
toElfData 2 = Just $ ELFDATA2MSB
toElfData _ = Nothing

fromElfData :: ElfData -> Word8
fromElfData ELFDATA2LSB = 1
fromElfData ELFDATA2MSB = 2

------------------------------------------------------------------------
-- ElfGOT

-- | A global offset table section.
data ElfGOT w = ElfGOT
    { elfGotIndex     :: !Word16
    , elfGotName      :: !B.ByteString -- ^ Name of section.
    , elfGotAddr      :: !w
    , elfGotAddrAlign :: !w
    , elfGotEntSize   :: !w
    , elfGotData      :: !B.ByteString
    } deriving (Show)

elfGotSize :: Num w => ElfGOT w -> w
elfGotSize g = fromIntegral (B.length (elfGotData g))

elfGotSectionFlags :: (Bits w, Num w) => ElfSectionFlags w
elfGotSectionFlags = shf_write .|. shf_alloc

-- | Convert a GOT section to a standard section.
elfGotSection :: (Bits w, Num w) => ElfGOT w -> ElfSection w
elfGotSection g =
  ElfSection { elfSectionIndex = elfGotIndex g
             , elfSectionName = elfGotName g
             , elfSectionType = SHT_PROGBITS
             , elfSectionFlags = elfGotSectionFlags
             , elfSectionAddr = elfGotAddr g
             , elfSectionSize = elfGotSize g
             , elfSectionLink = 0
             , elfSectionInfo = 0
             , elfSectionAddrAlign = elfGotAddrAlign g
             , elfSectionEntSize = elfGotEntSize g
             , elfSectionData = elfGotData g
             }

------------------------------------------------------------------------
-- ElfSymbolTableEntry

-- | The symbol table entries consist of index information to be read from other
-- parts of the ELF file.
--
-- Some of this information is automatically retrieved
-- for your convenience (including symbol name, description of the enclosing
-- section, and definition).
data ElfSymbolTableEntry w = EST
    { steName             :: !B.ByteString
      -- ^ This is the name of the symbol
      --
      -- We use bytestrings for encoding the name rather than a 'Text'
      -- or 'String' value because the elf format does not specify an
      -- encoding for symbol table entries -- it only specifies that
      -- they are null-terminated.  This also makes checking equality
      -- and reading symbol tables faster.
    , steType             :: !ElfSymbolType
    , steBind             :: !ElfSymbolBinding
    , steOther            :: !Word8
    , steIndex            :: !ElfSectionIndex
      -- ^ Section in which the def is held
    , steValue            :: !w
      -- ^ Value associated with symbol.
    , steSize             :: !w
    } deriving (Eq, Show)

-- | Convert 8-bit symbol info to symbol type and binding.
infoToTypeAndBind :: Word8 -> (ElfSymbolType,ElfSymbolBinding)
infoToTypeAndBind i =
  let tp = ElfSymbolType (i .&. 0x0F)
      b = (i `shiftR` 4) .&. 0xF
   in (tp, ElfSymbolBinding b)

-- | Convert type and binding information to symbol info field.
typeAndBindToInfo :: ElfSymbolType -> ElfSymbolBinding -> Word8
typeAndBindToInfo (ElfSymbolType tp) (ElfSymbolBinding b) = tp .|. (b `shiftL` 4)

------------------------------------------------------------------------
-- ElfSymbolTable

-- | This entry corresponds to the symbol table index.
data ElfSymbolTable w
  = ElfSymbolTable { elfSymbolTableIndex :: !Word16
                     -- ^ Index of section storing symbol table
                   , elfSymbolTableEntries :: !(V.Vector (ElfSymbolTableEntry w))
                     -- ^ Vector of symbol table entries.
                     --
                     -- Local entries should appear before global entries in vector.
                   , elfSymbolTableLocalEntries :: !Word32
                     -- ^ Number of local entries in table.
                     -- First entry should be a local entry.
                   } deriving (Show)

------------------------------------------------------------------------
-- ElfSegmentType

-- | The type of an elf segment
newtype ElfSegmentType = ElfSegmentType { fromElfSegmentType :: Word32 }
  deriving (Eq,Ord)

-- | Unused entry
pattern PT_NULL :: ElfSegmentType
pattern PT_NULL    = ElfSegmentType 0
-- | Loadable program segment
pattern PT_LOAD :: ElfSegmentType
pattern PT_LOAD    = ElfSegmentType 1
-- | Dynamic linking information
pattern PT_DYNAMIC :: ElfSegmentType
pattern PT_DYNAMIC = ElfSegmentType 2
-- | Program interpreter path name
pattern PT_INTERP :: ElfSegmentType
pattern PT_INTERP  = ElfSegmentType 3
-- | Note sections
pattern PT_NOTE :: ElfSegmentType
pattern PT_NOTE    = ElfSegmentType 4
-- | Reserved
pattern PT_SHLIB :: ElfSegmentType
pattern PT_SHLIB   = ElfSegmentType 5
-- | Program header table
pattern PT_PHDR :: ElfSegmentType
pattern PT_PHDR    = ElfSegmentType 6
-- | A thread local storage segment
--
-- See 'https://www.akkadia.org/drepper/tls.pdf'
pattern PT_TLS :: ElfSegmentType
pattern PT_TLS     = ElfSegmentType 7
-- | A number of defined types.
pattern PT_NUM :: ElfSegmentType
pattern PT_NUM     = ElfSegmentType 8

-- | Start of OS-specific
pattern PT_LOOS :: ElfSegmentType
pattern PT_LOOS    = ElfSegmentType 0x60000000

-- | The GCC '.eh_frame_hdr' segment
pattern PT_GNU_EH_FRAME :: ElfSegmentType
pattern PT_GNU_EH_FRAME = ElfSegmentType 0x6474e550

-- | Indicates if stack should be executable.
pattern PT_GNU_STACK :: ElfSegmentType
pattern PT_GNU_STACK = ElfSegmentType 0x6474e551

-- | GNU-specific segment type used to indicate that a loadable
-- segment is initially writable, but can be made read-only after
-- relocations have been applied.
pattern PT_GNU_RELRO :: ElfSegmentType
pattern PT_GNU_RELRO = ElfSegmentType 0x6474e552

-- | Indicates this binary uses PAX.
pattern PT_PAX_FLAGS :: ElfSegmentType
pattern PT_PAX_FLAGS = ElfSegmentType 0x65041580

-- | End of OS-specific
pattern PT_HIOS :: ElfSegmentType
pattern PT_HIOS    = ElfSegmentType 0x6fffffff

-- | Start of OS-specific
pattern PT_LOPROC :: ElfSegmentType
pattern PT_LOPROC  = ElfSegmentType 0x70000000
-- | End of OS-specific
pattern PT_HIPROC :: ElfSegmentType
pattern PT_HIPROC  = ElfSegmentType 0x7fffffff

elfSegmentTypeNameMap :: Map.Map ElfSegmentType String
elfSegmentTypeNameMap = Map.fromList $
  [ (,) PT_NULL         "NULL"
  , (,) PT_LOAD         "LOAD"
  , (,) PT_DYNAMIC      "DYNAMIC"
  , (,) PT_INTERP       "INTERP"
  , (,) PT_NOTE         "NOTE"
  , (,) PT_SHLIB        "SHLIB"
  , (,) PT_PHDR         "PHDR"
  , (,) PT_TLS          "TLS"
  , (,) PT_GNU_EH_FRAME "GNU_EH_FRAME"
  , (,) PT_GNU_STACK    "GNU_STACK"
  , (,) PT_GNU_RELRO    "GNU_RELRO"
  , (,) PT_PAX_FLAGS    "PAX_FLAGS"
  ]

instance Show ElfSegmentType where
  show tp =
    case Map.lookup tp elfSegmentTypeNameMap of
      Just s -> "PT_" ++ s
      Nothing -> "0x" ++ showHex (fromElfSegmentType tp) ""

------------------------------------------------------------------------
-- ElfSegmentFlags

-- | The flags (permission bits on an elf segment.
newtype ElfSegmentFlags  = ElfSegmentFlags { fromElfSegmentFlags :: Word32 }
  deriving (Eq, Num, Bits)

instance Show ElfSegmentFlags where
  showsPrec d (ElfSegmentFlags w) = showFlags "pf_none" names d w
    where names = V.fromList [ "pf_x", "pf_w", "pf_r" ]

-- | No permissions
pf_none :: ElfSegmentFlags
pf_none = ElfSegmentFlags 0

-- | Execute permission
pf_x :: ElfSegmentFlags
pf_x = ElfSegmentFlags 1

-- | Write permission
pf_w :: ElfSegmentFlags
pf_w = ElfSegmentFlags 2

-- | Read permission
pf_r :: ElfSegmentFlags
pf_r = ElfSegmentFlags 4

------------------------------------------------------------------------
-- ElfMemSize

-- | This describes the size of a elf section or segment memory size.
data ElfMemSize w
   = ElfAbsoluteSize !w
     -- ^ The region  has the given absolute size.
     --
     -- Note that when writing out files, we will only use this size if it is larger
     -- than the computed size, otherwise we use the computed size.
   | ElfRelativeSize !w
     -- ^ The given offset should be added to the computed size.
  deriving (Show)

------------------------------------------------------------------------
-- ElfSegment and ElfDataRegion

-- | The index to use for a segment in the program header table.
type SegmentIndex = Word16

-- | Information about an elf segment
--
-- The parameter should be a 'Word32' or 'Word64' depending on whether this
-- is a 32 or 64-bit elf file.
data ElfSegment (w :: Nat) = ElfSegment
  { elfSegmentType      :: !ElfSegmentType
    -- ^ Segment type
  , elfSegmentFlags     :: !ElfSegmentFlags
    -- ^ Segment flags
  , elfSegmentIndex     :: !SegmentIndex
    -- ^ A 0-based index indicating the position of the segment in the Phdr table
    --
    -- The index of a segment should be unique and range from '0' to one less than
    -- the number of segments in the Elf file.
    -- Since the phdr table is typically stored in a loaded segment, the number of
    -- entries affects the layout of binaries.
  , elfSegmentVirtAddr  :: !(ElfWordType w)
    -- ^ Virtual address for the segment.
    --
    -- The elf standard for some ABIs proscribes that the virtual address for a
    -- file should be in ascending order of the segment addresses.  This does not
    -- appear to be the case for the x86 ABI documents, but valgrind warns of it.
  , elfSegmentPhysAddr  :: !(ElfWordType w)
    -- ^ Physical address for the segment.
    --
    -- This contents are typically not used on executables and shared libraries
    -- as they are not loaded at fixed physical addresses.  The convention
    -- seems to be to set the phyiscal address equal to the virtual address.
  , elfSegmentAlign     :: !(ElfWordType w)
    -- ^ The value to which this segment is aligned in memory and the file.
    -- This field is called @p_align@ in Elf documentation.
    --
    -- A value of 0 or 1 means no alignment is required.  This gives the
    -- value to which segments are loaded in the file.  If it is not 0 or 1,
    -- then is hould be a positve power of two.  'elfSegmentVirtAddr' should
    -- be congruent to the segment offset in the file modulo 'elfSegmentAlign'.
    -- e.g., if file offset is 'o', alignment is 'n', and virtual address is 'a',
    -- then 'o mod n = a mod n'
    --
    -- Note that when writing files, no effort is made to add padding so that the
    -- alignment property is expected.  It is up to the user to insert raw data segments
    -- as needed for padding.  We considered inserting padding automatically, but this
    -- can result in extra bytes inadvertently appearing in loadable segments, thus
    -- breaking layout constraints.
  , elfSegmentMemSize   :: !(ElfMemSize (ElfWordType w))
    -- ^ Size in memory (may be larger then segment data)
  , elfSegmentData     :: !(Seq.Seq (ElfDataRegion w))
    -- ^ Regions contained in segment.
  }

-- | A region of data in the file.
data ElfDataRegion w
   = ElfDataElfHeader
     -- ^ Identifies the elf header
     --
     -- This should appear 1st in an in-order traversal of the file.
     -- This is represented explicitly as an elf data region as it may be part of
     -- an elf segment, and thus we need to know whether a segment contains it.
   | ElfDataSegmentHeaders
     -- ^ Identifies the program header table.
     --
     -- This is represented explicitly as an elf data region as it may be part of
     -- an elf segment, and thus we need to know whether a segment contains it.
   | ElfDataSegment !(ElfSegment w)
     -- ^ A segment that contains other segments.
   | ElfDataSectionHeaders
     -- ^ Identifies the section header table.
     --
     -- This is represented explicitly as an elf data region as it may be part of
     -- an elf segment, and thus we need to know whether a segment contains it.
   | ElfDataSectionNameTable !Word16
     -- ^ The section for storing the section names.
     --
     -- The contents are auto-generated, so we only need to know which section
     -- index to give it.
   | ElfDataGOT !(ElfGOT (ElfWordType w))
     -- ^ A global offset table.
   | ElfDataStrtab !Word16
     -- ^ Elf strtab section (with index)
   | ElfDataSymtab !(ElfSymbolTable (ElfWordType w))
     -- ^ Elf symtab section
   | ElfDataSection !(ElfSection (ElfWordType w))
     -- ^ A section that has no special interpretation.
   | ElfDataRaw B.ByteString
     -- ^ Identifies an uninterpreted array of bytes.

deriving instance ElfWidthConstraints w => Show (ElfDataRegion w)

-- | This applies a function to each data region in an elf file, returning
-- the sum using 'Alternative' operations for combining results.
asumDataRegions :: Alternative f => (ElfDataRegion w -> f a) -> Elf w -> f a
asumDataRegions f e = F.asum $ g <$> e^.elfFileData
  where g r@(ElfDataSegment s) = f r <|> F.asum (g <$> elfSegmentData s)
        g r = f r

ppSegment :: ElfWidthConstraints w => ElfSegment w -> Doc
ppSegment s =
  text "type: " <+> ppShow (elfSegmentType s) <$$>
  text "flags:" <+> ppShow (elfSegmentFlags s) <$$>
  text "index:" <+> ppShow (elfSegmentIndex s) <$$>
  text "vaddr:" <+> text (ppHex (elfSegmentVirtAddr s)) <$$>
  text "paddr:" <+> text (ppHex (elfSegmentPhysAddr s)) <$$>
  text "align:" <+> ppShow (elfSegmentAlign s) <$$>
  text "msize:" <+> ppShow (elfSegmentMemSize s) <$$>
  text "data:"  <$$>
  indent 2 (vcat . map ppRegion . F.toList $ elfSegmentData s)

ppRegion :: ElfWidthConstraints w => ElfDataRegion w -> Doc
ppRegion r = case r of
  ElfDataElfHeader -> text "ELF header"
  ElfDataSegmentHeaders -> text "segment header table"
  ElfDataSegment s -> hang 2 (text "contained segment" <$$> ppSegment s)
  ElfDataSectionHeaders -> text "section header table"
  ElfDataSectionNameTable w -> text "section name table" <+> parens (text "section number" <+> ppShow w)
  ElfDataGOT got -> text "global offset table:" <+> ppShow got
  ElfDataStrtab w -> text "strtab section" <+> parens (text "section number" <+> ppShow w)
  ElfDataSymtab symtab -> text "symtab section:" <+> ppShow symtab
  ElfDataSection sec -> text "other section:" <+> ppShow sec
  ElfDataRaw bs -> text "raw bytes:" <+> ppShow bs

instance ElfWidthConstraints w => Show (ElfSegment w) where
  show s = show (ppSegment s)

------------------------------------------------------------------------
-- ElfHeader

-- | Elf header information that does not need further parsing.
data ElfHeader w = ElfHeader { headerData       :: !ElfData
                             , headerClass      :: !(ElfClass w)
                             , headerOSABI      :: !ElfOSABI
                             , headerABIVersion :: !Word8
                             , headerType       :: !ElfType
                             , headerMachine    :: !ElfMachine
                             , headerEntry      :: !(ElfWordType w)
                             , headerFlags      :: !Word32
                             }

------------------------------------------------------------------------
-- GnuRelroRegion

-- | Information about a PT_GNU_STACK segment.
data GnuStack =
  GnuStack { gnuStackSegmentIndex :: !SegmentIndex
             -- ^ Index to use for GNU stack.
           , gnuStackIsExecutable :: !Bool
             -- ^ Flag that indicates whether the stack should be executable.
           }

------------------------------------------------------------------------
-- GnuRelroRegion

-- | Information about a PT_GNU_RELRO segment
data GnuRelroRegion w =
  GnuRelroRegion { relroSegmentIndex :: !SegmentIndex
                 -- ^ Index to use for Relro region.
                 , relroRefSegmentIndex :: !SegmentIndex
                 -- ^ Index of the segment this relro refers to.
                 , relroAddrStart :: !(ElfWordType w)
                 -- ^ Identifies the base virtual address of the
                 -- region that should be made read-only.
                 --
                 -- This is typically the base address of the segment,
                 -- but could be an offset.  The actual address used is
                 -- the relro rounded down.
                 , relroSize :: !(ElfWordType w)
                 -- ^ Size of relro protection in number of bytes.
                 }

------------------------------------------------------------------------
-- Elf

-- | The version of elf files supported by this parser
expectedElfVersion :: Word8
expectedElfVersion = 1

-- | The contents of an Elf file.  Many operations require that the
-- width parameter is either @Word32@ or @Word64@ dependings on whether
-- this is a 32-bit or 64-bit file.
data Elf w = Elf
    { elfData       :: !ElfData       -- ^ Identifies the data encoding of the object file.
    , elfClass      :: !(ElfClass w)  -- ^ Identifies width of elf class.
    , elfOSABI      :: !ElfOSABI
      -- ^ Identifies the operating system and ABI for which the object is prepared.
    , elfABIVersion :: !Word8
      -- ^ Identifies the ABI version for which the object is prepared.
    , elfType       :: !ElfType       -- ^ Identifies the object file type.
    , elfMachine    :: !ElfMachine    -- ^ Identifies the target architecture.
    , elfEntry      :: !(ElfWordType w)
      -- ^ Virtual address of the program entry point.
      --
      -- 0 for non-executable Elfs.
    , elfFlags      :: !Word32
      -- ^ Machine specific flags
    , _elfFileData  :: Seq.Seq (ElfDataRegion w)
      -- ^ Data to be stored in elf file.
    , elfGnuStackSegment :: !(Maybe GnuStack)
      -- ^ PT_GNU_STACK segment info (if any).
      --
      -- If present, this tells loaders that support it whether to set the executable
    , elfGnuRelroRegions :: ![GnuRelroRegion w]
      -- ^ PT_GNU_RELRO regions.
    }

-- | Create an empty elf file.
emptyElf :: ElfData -> ElfClass w -> ElfType -> ElfMachine -> Elf w
emptyElf d c tp m = elfClassInstances c $
  Elf { elfData       = d
      , elfClass      = c
      , elfOSABI      = ELFOSABI_SYSV
      , elfABIVersion = 0
      , elfType       = tp
      , elfMachine    = m
      , elfEntry      = 0
      , elfFlags      = 0
      , _elfFileData  = Seq.empty
      , elfGnuStackSegment = Nothing
      , elfGnuRelroRegions = []
      }

-- | Return the header information about the elf
elfHeader :: Elf w -> ElfHeader w
elfHeader e = ElfHeader { headerData       = elfData e
                        , headerClass      = elfClass e
                        , headerOSABI      = elfOSABI e
                        , headerABIVersion = elfABIVersion e
                        , headerType       = elfType e
                        , headerMachine    = elfMachine e
                        , headerEntry      = elfEntry e
                        , headerFlags      = elfFlags e
                        }

-- | Lens to access top-level regions in Elf file.
elfFileData :: Simple Lens (Elf w) (Seq.Seq (ElfDataRegion w))
elfFileData = lens _elfFileData (\s v -> s { _elfFileData = v })
