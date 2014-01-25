{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, DeriveDataTypeable #-}
-- | Simple interface for shell scripting-like tasks.
module Control.Shell ( 
    Shell, shell,
    mayFail, orElse,
    withEnv, getEnv, lookupEnv,
    run, run_, runInteractive, sudo,
    cd, cpDir, pwd, ls, mkdir, rmdir, inDirectory, isDirectory,
    withHomeDirectory, inHomeDirectory, withAppDirectory, inAppDirectory,
    isFile, rm, mv, cp, file,
    withTempFile, withTempDirectory, inTempDirectory,
    hPutStr, hPutStrLn, echo,
    module System.FilePath,
  ) where
import Control.Applicative
import Control.Monad (ap)
import Control.Monad.IO.Class
import Data.Time.Clock
import Data.Typeable
import System.FilePath
import qualified System.Process as Proc
import qualified System.Directory as Dir
import qualified System.Exit as Exit
import qualified System.IO as IO
import qualified Control.Exception as Ex
import qualified Control.Concurrent as Conc
import qualified System.IO.Temp as Temp
import qualified System.Environment as Env

newtype ShellException = ShellException String deriving (Typeable, Show)
instance Ex.Exception ShellException

-- | Environment variables.
type Env = [(String, String)]

-- | A command name plus a ProcessHandle.
data Pid = Pid {pidName :: String, pidHandle :: Proc.ProcessHandle}

-- | Monad for running shell commands. If a command fails, the entire
--   computation is aborted unless @mayFail@ is used.
newtype Shell a = Shell {
    unSh :: Env -> IO (Either String a, [Pid])
  }

instance Monad Shell where
  fail err = Shell $ \_ -> return (Left err, [])
  return x = Shell $ \_ -> return (Right x, [])
  -- | The bind operation of the Shell monad is effectively a barrier; all
  --   commands on the left hand side of a bind will complete before any
  --   command on the right hand side is attempted.
  --   To lazily stream data between two commands, use the @|>@ combinator.
  (Shell m) >>= f = Shell $ \env -> do
    (x, pids) <- m env
    merr <- waitPids pids
    case (x, merr) of
      (Left err, _) -> return (Left err, [])
      (_, Just err) -> return (Left err, [])
      (Right x', _) -> unSh (f x') env

instance MonadIO Shell where
  liftIO act = Shell $ \_ -> flip Ex.catch exHandler $ do
    x <- act
    return (Right x, [])

instance Applicative Shell where
  pure  = return
  (<*>) = ap

instance Functor Shell where
  fmap f x = do
    x' <- x
    return $! f x'

-- | Enable the user to use 'file "foo" |> fmap reverse |> file "bar"' as
--   syntax for reading the file 'foo', reversing the contents and writing the
--   result to 'bar'.
--   Note that this uses lazy IO in the form of read/writeFile.
class File a where
  file :: FilePath -> a

instance File (String -> Shell ()) where
  file f = liftIO . writeFile f

instance File (Shell String) where
  file f = liftIO $ readFile f

-- | Lazy counterpart to monadic bind. To stream data from a command 'a' to a
--   command 'b', do 'a |> b'.
(|>) :: Shell String -> (String -> Shell a) -> Shell a
(Shell m) |> f = Shell $ \env -> do
  (x, pids) <- m env
  (x', pids') <- case x of
    Left err -> return (Left err, [])
    Right x' -> unSh (f x') env
  return (x', pids ++ pids')
infixl 1 |>

-- | Wait for all processes in the given list. If a process has failed, its
--   error message is returned and the rest are killed.
waitPids :: [Pid] -> IO (Maybe String)
waitPids (p:ps) = do
  exCode <- Proc.waitForProcess (pidHandle p)
  case exCode of
    Exit.ExitFailure ec -> do
      killPids ps
      return . Just $ "Command '" ++ (pidName p) ++ "' failed with error "
                    ++" code " ++ show ec
    _ -> do
      waitPids ps
waitPids _ = do
  return Nothing

-- | Kill all processes in the list.
killPids :: [Pid] -> IO ()
killPids = mapM_ (Proc.terminateProcess . pidHandle)

-- | Run a Shell computation. The program's working directory  will be restored 
--   after executing the computation.
shell :: Shell a -> IO (Either String a)
shell act = do
  dir <- Dir.getCurrentDirectory
  env <- Env.getEnvironment
  (res, pids) <- unSh act env
  merr <- waitPids pids
  Dir.setCurrentDirectory dir
  case merr of
    Just err -> return $ Left err
    _        -> return res

-- | Run a computation with a new value for an environment variable.
--   Note that this will *not* affect external commands spawned using @liftIO@
--   or which directory is considered the system temp directory.
withEnv :: String -> (String -> String) -> Shell a -> Shell a
withEnv key f (Shell act) = Shell $ \env -> do
    act $ insert env
  where
    insert (x@(k,v):xs) | k == key  = (key, f v) : xs
                        | otherwise = x : insert xs
    insert _                        = [(key, f "")]

-- | Get the value of an environment variable. Returns Nothing if the variable 
--   doesn't exist.
lookupEnv :: String -> Shell (Maybe String)
lookupEnv key = Shell $ \env -> return (Right $ lookup key env, [])

-- | Get the value of an environment variable. Returns the empty string if
--   the variable doesn't exist.
getEnv :: String -> Shell String
getEnv key = maybe "" id `fmap` lookupEnv key

-- | General exception handler; any exception causes failure.
exHandler :: Ex.SomeException -> IO (Either String a, [Pid])
exHandler x = return (Left $ show x, [])

-- | Execute an external command. No globbing, escaping or other external shell
--   magic is performed on either the command or arguments. The program's text
--   output will be returned, and not echoed to the screen.
run :: FilePath -> [String] -> String -> Shell String
run p args stdin = do
  (Just inp, Just out, pid) <- runP p args Proc.CreatePipe Proc.CreatePipe
  Shell $ \_ -> do
    let feed str = do
          case splitAt 4096 str of
            ([], [])      -> IO.hClose inp
            (first, str') -> IO.hPutStr inp first >> feed str'
    Conc.forkIO $ feed stdin
    s <- IO.hGetContents out
    return (Right s, [Pid p pid])

-- | Like @run@, but echoes the command's text output to the screen instead of
--   returning it.
run_ :: FilePath -> [String] -> String -> Shell ()
run_ p args stdin = do
  (Just inp, _, pid) <- runP p args Proc.CreatePipe Proc.Inherit
  exCode <- liftIO $ do
    IO.hPutStr inp stdin
    IO.hClose inp
    Proc.waitForProcess pid
  case exCode of
    Exit.ExitFailure ec -> fail $ "Command '" ++ p ++ "' failed with error " 
                                ++" code " ++ show ec
    _                   -> return ()

-- | Run a command with elevated privileges.
sudo :: FilePath -> [String] -> String -> Shell String
sudo cmd args stdin = run "sudo" (cmd:args) stdin

-- | Create a process. Helper for @run@ and friends.
runP :: String
     -> [String]
     -> Proc.StdStream
     -> Proc.StdStream
     -> Shell (Maybe IO.Handle, Maybe IO.Handle, Proc.ProcessHandle)
runP p args stdin stdout = Shell $ \env -> do
    (inp, out, _, pid) <- Proc.createProcess (cproc env)
    return (Right (inp, out, pid), [])
  where
    cproc env = Proc.CreateProcess {
        Proc.cmdspec      = Proc.RawCommand p args,
        Proc.cwd          = Nothing,
        Proc.env          = Just env,
        Proc.std_in       = stdin,
        Proc.std_out      = stdout,
        Proc.std_err      = Proc.Inherit,
        Proc.close_fds    = False,
        Proc.create_group = False
      }

-- | Run an interactive process.
runInteractive :: FilePath -> [String] -> Shell ()
runInteractive p args = do
  (_, _, pid) <- runP p args Proc.Inherit Proc.Inherit
  exitCode <- liftIO $ Proc.waitForProcess pid
  case exitCode of
    Exit.ExitFailure ec -> fail (show ec)
    _                   -> return ()

-- | Change working directory.
cd :: FilePath -> Shell ()
cd = liftIO . Dir.setCurrentDirectory

-- | Get the current working directory.
pwd :: Shell FilePath
pwd = liftIO $ Dir.getCurrentDirectory

-- | Remove a file.
rm :: FilePath -> Shell ()
rm = liftIO . Dir.removeFile

-- | Rename a file.
mv :: FilePath -> FilePath -> Shell ()
mv from to = liftIO $ Dir.renameFile from to

-- | Recursively copy a directory. If the target is a directory that already
--   exists, the source directory is copied into that directory using its
--   current name.
cpDir :: FilePath -> FilePath -> Shell ()
cpDir from to = do
  todir <- isDirectory to
  if todir
    then do
      cpDir from (to </> takeBaseName from)
    else do
      cpfile <- isFile from
      if cpfile
        then do
          cp from to
        else do
          liftIO $ Dir.createDirectoryIfMissing False to
          ls from >>= mapM_ (\f -> cpDir (from </> f) (to </> f))

-- | Copy a file. Fails if the source is a directory. If the target is a
--   directory, the source file is copied into that directory using its current
--   name.
cp :: FilePath -> FilePath -> Shell ()
cp from to = do
  todir <- isDirectory to
  if todir
    then cp from (to </> takeFileName from)
    else liftIO $ Dir.copyFile from to

-- | List the contents of a directory, sans '.' and '..'.
ls :: FilePath -> Shell [FilePath]
ls dir = do
  contents <- liftIO $ Dir.getDirectoryContents dir
  return [f | f <- contents, f /= ".", f /= ".."]

-- | Create a directory. Optionally create any required missing directories as
--   well.
mkdir :: Bool -> FilePath -> Shell ()
mkdir True = liftIO . Dir.createDirectoryIfMissing True
mkdir _    = liftIO . Dir.createDirectory

-- | Recursively remove a directory. Follows symlinks, so be careful.
rmdir :: FilePath -> Shell ()
rmdir = liftIO . Dir.removeDirectoryRecursive

-- | Do something with the user's home directory.
withHomeDirectory :: (FilePath -> Shell a) -> Shell a
withHomeDirectory act = liftIO Dir.getHomeDirectory >>= act

-- | Do something *in* the user's home directory.
inHomeDirectory :: Shell a -> Shell a
inHomeDirectory act = withHomeDirectory $ \dir -> inDirectory dir act

-- | Do something with the given application's data directory.
withAppDirectory :: String -> (FilePath -> Shell a) -> Shell a
withAppDirectory app act = liftIO (Dir.getAppUserDataDirectory app) >>= act

-- | Do something *in* the given application's data directory.
inAppDirectory :: FilePath -> Shell a -> Shell a
inAppDirectory app act = withAppDirectory app $ \dir -> inDirectory dir act

-- | Execute a command in the given working directory, then restore the
--   previous working directory.
inDirectory :: FilePath -> Shell a -> Shell a
inDirectory dir act = do
  curDir <- pwd
  cd dir
  x <- act
  cd curDir
  return x

-- | Does the given path lead to a directory?
isDirectory :: FilePath -> Shell Bool
isDirectory = liftIO . Dir.doesDirectoryExist

-- | Does the given path lead to a file?
isFile :: FilePath -> Shell Bool
isFile = liftIO . Dir.doesFileExist

-- | Create a temp directory in the standard system temp directory, do
--   something with it, then remove it.
withTempDirectory :: String -> (FilePath -> Shell a) -> Shell a
withTempDirectory template act = Shell $ \env -> do
    Temp.withSystemTempDirectory template (act' env)
  where
    act' env fp = Ex.catch (unSh (act fp) env) exHandler

-- | Performs a command inside a temporary directory. The directory will be
--   cleaned up after the command finishes.
inTempDirectory :: Shell a -> Shell a
inTempDirectory = withTempDirectory "hsshell" . flip inDirectory

-- | Create a temp file in the standard system temp directory, do something
--   with it, then remove it.
withTempFile :: String -> (FilePath -> IO.Handle -> Shell a) -> Shell a
withTempFile template act = Shell $ \env -> do
    Temp.withSystemTempFile template (act' env)
  where
    act' env fp h = Ex.catch (unSh (act fp h) env) exHandler

-- | Perform an action that may fail without aborting the entire computation.
--   Forces serialization.
mayFail :: Shell a -> Shell (Either String a)
mayFail (Shell act) = Shell $ \env -> do
  (x, pids) <- Ex.catch (act env) exHandler
  merr <- waitPids pids
  case merr of
    Just err -> return (Right (Left err), [])
    _        -> return (Right x, [])

-- | Attempt to run the first command. If the first command fails, run the
--   second. Forces serialization of the first command.
orElse :: Shell a -> Shell a -> Shell a
orElse a b = do
  ex <- mayFail a
  case ex of
    Right x -> return x
    _       -> b

-- | @IO.hPutStr@ lifted into Shell for convenience.
hPutStr :: IO.Handle -> String -> Shell ()
hPutStr h s = liftIO $ IO.hPutStr h s

-- | @IO.hPutStrLn@ lifted into Shell for convenience.
hPutStrLn :: IO.Handle -> String -> Shell ()
hPutStrLn h s = liftIO $ IO.hPutStrLn h s

-- | @putStrLn@ lifted into Shell for convenience.
echo :: String -> Shell ()
echo = liftIO . putStrLn