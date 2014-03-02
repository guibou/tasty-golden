{- |
This module provides a simplified interface. If you want more, see
"Test.Tasty.Golden.Advanced".

Note about filenames. They are looked up in the usual way, thus relative
names are relative to the processes current working directory.
It is common to run tests from the package's root directory (via @cabal
test@ or @cabal install --enable-tests@), so if your test files are under
the @tests\/@ subdirectory, your relative file names should start with
@tests\/@ (even if your @test.hs@ is itself under @tests\/@, too).

-}
module Test.Tasty.Golden
  ( goldenVsFile
  , goldenVsString
  , goldenVsFileDiff
  , goldenVsStringDiff
  , writeBinaryFile
  )
  where

import Test.Tasty.Providers
import Test.Tasty.Golden.Advanced
import Text.Printf
import qualified Data.ByteString.Lazy as LB
import System.IO
import System.IO.Temp
import System.Process
import System.Exit
import System.FilePath
import Control.Exception
import Control.Monad
import Control.DeepSeq

-- trick to avoid an explicit dependency on transformers
import Control.Monad.Error (liftIO)

-- | Compare a given file contents against the golden file contents
goldenVsFile
  :: TestName -- ^ test name
  -> FilePath -- ^ path to the «golden» file (the file that contains correct output)
  -> FilePath -- ^ path to the output file
  -> IO () -- ^ action that creates the output file
  -> TestTree -- ^ the test verifies that the output file contents is the same as the golden file contents
goldenVsFile name ref new act =
  goldenTest
    name
    (vgReadFile ref)
    (liftIO act >> vgReadFile new)
    cmp
    upd
  where
  cmp = simpleCmp $ printf "Files '%s' and '%s' differ" ref new
  upd = LB.writeFile ref

-- | Compare a given string against the golden file contents
goldenVsString
  :: TestName -- ^ test name
  -> FilePath -- ^ path to the «golden» file (the file that contains correct output)
  -> IO LB.ByteString -- ^ action that returns a string
  -> TestTree -- ^ the test verifies that the returned string is the same as the golden file contents
goldenVsString name ref act =
  goldenTest
    name
    (vgReadFile ref)
    (liftIO act)
    cmp
    upd
  where
  cmp x y = simpleCmp msg x y
    where
    msg = printf "Test output was different from '%s'. It was: %s" ref (show y)
  upd = LB.writeFile ref

simpleCmp :: Eq a => String -> a -> a -> IO (Maybe String)
simpleCmp e x y =
  return $ if x == y then Nothing else Just e

-- | Same as 'goldenVsFile', but invokes an external diff command.
goldenVsFileDiff
  :: TestName -- ^ test name
  -> (FilePath -> FilePath -> [String])
    -- ^ function that constructs the command line to invoke the diff
    -- command.
    --
    -- E.g.
    --
    -- >\ref new -> ["diff", "-u", ref, new]
  -> FilePath -- ^ path to the golden file
  -> FilePath -- ^ path to the output file
  -> IO ()    -- ^ action that produces the output file
  -> TestTree
goldenVsFileDiff name cmdf ref new act =
  goldenTest
    name
    (return ())
    (liftIO act)
    cmp
    upd
  where
  cmd = cmdf ref new
  cmp _ _ | null cmd = error "goldenVsFileDiff: empty command line"
  cmp _ _ = do
    (_, Just sout, _, pid) <- createProcess (proc (head cmd) (tail cmd)) { std_out = CreatePipe }
    -- strictly read the whole output, so that the process can terminate
    out <- hGetContents sout
    evaluate . rnf $ out

    r <- waitForProcess pid
    return $ case r of
      ExitSuccess -> Nothing
      _ -> Just out

  upd _ = LB.readFile new >>= LB.writeFile ref

-- | Same as 'goldenVsString', but invokes an external diff command.
goldenVsStringDiff
  :: TestName -- ^ test name
  -> (FilePath -> FilePath -> [String])
    -- ^ function that constructs the command line to invoke the diff
    -- command.
    --
    -- E.g.
    --
    -- >\ref new -> ["diff", "-u", ref, new]
  -> FilePath -- ^ path to the golden file
  -> IO LB.ByteString -- ^ action that returns a string
  -> TestTree
goldenVsStringDiff name cmdf ref act =
  goldenTest
    name
    (vgReadFile ref)
    (liftIO act)
    cmp
    upd
  where
  template = takeFileName ref <.> "actual"
  cmp _ actBS = withSystemTempFile template $ \tmpFile tmpHandle -> do

    -- Write act output to temporary ("new") file
    LB.hPut tmpHandle actBS >> hFlush tmpHandle

    let cmd = cmdf ref tmpFile

    when (null cmd) $ error "goldenVsFileDiff: empty command line"

    (_, Just sout, _, pid) <- createProcess (proc (head cmd) (tail cmd)) { std_out = CreatePipe }
    -- strictly read the whole output, so that the process can terminate
    out <- hGetContents sout
    evaluate . rnf $ out

    r <- waitForProcess pid
    return $ case r of
      ExitSuccess -> Nothing
      _ -> Just (printf "Test output was different from '%s'. Output of %s:\n%s" ref (show cmd) out)

  upd = LB.writeFile ref

-- | Like 'writeFile', but uses binary mode
writeBinaryFile :: FilePath -> String -> IO ()
writeBinaryFile f txt = withBinaryFile f WriteMode (\hdl -> hPutStr hdl txt)
