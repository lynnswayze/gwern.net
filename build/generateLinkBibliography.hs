#!/usr/bin/env runhaskell
{-# LANGUAGE OverloadedStrings #-}
module Main where

-- Generate "link bibliographies" for Gwern.net pages.
-- Link bibliographies are similar to directory indexes in compiling a list of all links on a Gwern.net page/essay, in order, with their annotations (where available). They are the forward-citation dual of backlinks, are much easier to synoptically browse than mousing over links one at a time, and can help provide a static version of the page (ie download page + link bibliography to preserve the annotations).
--
-- Link bibliographies are generated by parsing each $PAGE (provided in default.html as '$url$'), filtering for Links using the Pandoc API, querying the metadata, generating a numbered list of links, and then writing out the generated Markdown file to 'docs/link-bibliography/$PAGE.page'. They are compiled like normal pages by Hakyll, and they are exposed to readers as an additional link in the page metadata block, paired with the backlinks.

import Data.List (isPrefixOf, isSuffixOf, nub)
import Data.List.Utils (replace)
import Data.Text.Titlecase (titlecase)
import qualified Data.Map as M (lookup)
import System.Directory (doesFileExist, renameFile, removeFile, createDirectoryIfMissing)
import System.Environment (getArgs)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (stderr, hPrint)
import System.IO.Temp (writeSystemTempFile)

import Data.Text.IO as TIO (readFile)
import qualified Data.Text as T (head, pack, unpack)

import Control.Monad.Parallel as Par (mapM_)

import Text.Pandoc (Inline(Code, Link, Str, Space), def, nullAttr, nullMeta, queryWith, readMarkdown, readerExtensions, writerExtensions, runPure, pandocExtensions, writeMarkdown, ListNumberDelim(DefaultDelim), ListNumberStyle(DefaultStyle), Block(Para, OrderedList), Pandoc(..))
import Text.Pandoc.Walk (walk)

import Interwiki (convertInterwikiLinks)
import LinkMetadata (generateAnnotationBlock, getBackLink, readLinkMetadata, authorsTruncate, Metadata, MetadataItem)

main :: IO ()
main = do pages <- getArgs
          md <- readLinkMetadata
          Par.mapM_ (generateLinkBibliography md) pages

generateLinkBibliography :: Metadata -> String -> IO ()
generateLinkBibliography md page = do links <- extractLinksFromPage page
                                      backlinks <- mapM getBackLink links
                                      let pairs = linksToAnnotations md links
                                          pairs' = zipWith (\(a,b) c -> (a,b,c)) pairs backlinks
                                          body = generateLinkBibliographyItems pairs'
                                          document = Pandoc nullMeta [body]
                                          markdown = runPure $ writeMarkdown def{writerExtensions = pandocExtensions} document
                                      case markdown of
                                        Left e   -> hPrint stderr e
                                        -- compare with the old version, and update if there are any differences:
                                        Right p' -> do let contentsNew = generateYAMLHeader (replace ".page" "" page) ++ T.unpack p'
                                                       updateFile ("docs/link-bibliography/" ++ page) contentsNew

updateFile :: FilePath -> String -> IO ()
updateFile f contentsNew = do t <- writeSystemTempFile "hakyll-link-bibliography" contentsNew
                              existsOld <- doesFileExist f
                              if not existsOld then
                                do createDirectoryIfMissing True (takeDirectory f)
                                   renameFile t f
                                else
                                  do contentsOld <- Prelude.readFile f
                                     if contentsNew /= contentsOld then renameFile t f else removeFile t

generateYAMLHeader :: FilePath -> String
generateYAMLHeader d = "---\n" ++
                       "title: " ++ d ++ " (Link Bibliography)\n" ++
                       "description: 'Annotated bibliography of links in the top-level page \"" ++ d ++ "\"'\n" ++
                       "tags: link-bibliography\n" ++
                       "created: 2009-01-01\n" ++
                       "status: in progress\n" ++
                       "confidence: log\n" ++
                       "importance: 0\n" ++
                       "cssExtension: drop-caps-de-zs\n" ++
                       "index: true\n" ++
                       "...\n" ++
                       "\n" ++
                       "<strong><a href=\"" ++ "/"++d ++ "\">\"" ++ d ++ "\"</a></strong> links:\n" ++
                       "\n"

generateLinkBibliographyItems :: [(String,MetadataItem,FilePath)] -> Block
generateLinkBibliographyItems items = OrderedList (1, DefaultStyle, DefaultDelim) $ map generateLinkBibliographyItem items
generateLinkBibliographyItem  :: (String,MetadataItem,FilePath) -> [Block]
generateLinkBibliographyItem (f,(t,aut,_,_,_,""),_)  = let f'
                                                             | "http" `isPrefixOf` f = f
                                                             | "index" `isSuffixOf` f = takeDirectory f
                                                             | otherwise = takeFileName f
                                                           author = if aut=="" then [] else [Str ",", Space, Str (T.pack $ authorsTruncate aut)]
                                                           -- I skip date because files don't usually have anything better than year, and that's already encoded in the filename which is shown
                                        in
                                          if t=="" then
                                            [Para (Link nullAttr [Code nullAttr (T.pack f')] (T.pack f, "") : author)]
                                          else
                                            [Para (Code nullAttr (T.pack f') :
                                                    Link nullAttr [Str ":", Space, Str "“", Str (T.pack $ titlecase t), Str "”"] (T.pack f, "") : author)]
generateLinkBibliographyItem (f,a,bl) = generateAnnotationBlock ("/"`isPrefixOf`f) True (f,Just a) bl

extractLinksFromPage :: String -> IO [String]
extractLinksFromPage path = do f <- TIO.readFile path
                               let pE = runPure $ readMarkdown def{readerExtensions=pandocExtensions} f
                               return $ case pE of
                                          Left  _ -> []
                                          -- make the list unique, but keep the original ordering
                                          Right p -> filter (\l -> not (head l == '#')) $ -- self-links are not useful in link bibliographies
                                                     nub $ extractLinks p -- TODO: maybe extract the title from the metadata for nicer formatting?
extractLinks :: Pandoc -> [String]
extractLinks p = queryWith extractLink $ walk convertInterwikiLinks p
extractLink :: Inline -> [String]
extractLink (Link _ _ (path, _)) = if T.head path == '$' || T.head path == '\8383' then [] else [T.unpack path]
extractLink _ = []

linksToAnnotations :: Metadata -> [String] -> [(String,MetadataItem)]
linksToAnnotations m = map (linkToAnnotation m)
linkToAnnotation :: Metadata -> String -> (String,MetadataItem)
linkToAnnotation m u = case M.lookup u m of
                         Just i  -> (u,i)
                         Nothing -> (u,("","","","",[],""))
