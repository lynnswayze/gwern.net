#!/usr/bin/env runghc
{-# LANGUAGE OverloadedStrings #-}
module Main where

-- Generate "link bibliographies" for Gwern.net pages.
--
-- Link bibliographies are similar to directory indexes in compiling a list of all links on a
-- Gwern.net page/essay, in order, with their annotations (where available). They are the
-- forward-citation dual of backlinks, are much easier to synoptically browse than mousing over
-- links one at a time, and can help provide a static version of the page (ie. download page + link
-- bibliography to preserve the annotations).
--
-- Link bibliographies are generated by parsing each $PAGE (provided in default.html as '$url$'),
-- filtering for Links using the Pandoc API, querying the metadata, generating a numbered list of
-- links, and then writing out the generated Markdown file to 'metadata/annotation/link-bibliography/$ESCAPED($PAGE).html'.
-- They are compiled like normal pages by Hakyll, and they are exposed to readers as an additional
-- link in the page metadata block, paired with the backlinks.

import Control.Monad (when)
import Data.List (isPrefixOf, isSuffixOf, sort, (\\))
import Data.Containers.ListUtils (nubOrd)
import Data.Text.Titlecase (titlecase)
import qualified Data.Map as M (lookup, keys)
import System.FilePath (takeDirectory, takeFileName)

import Data.Text.IO as TIO (readFile)
import qualified Data.Text as T (pack, unpack)
import System.Directory (doesFileExist, getModificationTime)
import Control.Monad.Parallel as Par (mapM_)

import Text.Pandoc (Inline(Code, Link, RawInline, Str, Strong), Format(Format), def, nullAttr, nullMeta, readMarkdown, readerExtensions, writerExtensions, runPure, pandocExtensions, ListNumberDelim(DefaultDelim), ListNumberStyle(DefaultStyle), Block(BlockQuote, Div, OrderedList, Para), Pandoc(..), writeHtml5String)
import Text.Pandoc.Walk (walk)

import LinkArchive (readArchiveMetadata, ArchiveMetadata)
import LinkBacklink (getLinkBibLink)
import LinkMetadata (generateAnnotationTransclusionBlock, readLinkMetadata, hasAnnotation, isPagePath)
import LinkMetadataTypes (Metadata, MetadataItem)
import Query (extractURLs, extractLinks)
import Typography (typographyTransform)
import Utils (writeUpdatedFile, replace, printRed)
import Interwiki (convertInterwikiLinks)
import qualified Config.Misc as C (mininumLinkBibliographyFragment)

main :: IO ()
main = do md <- readLinkMetadata
          am <- readArchiveMetadata
          -- build HTML fragments for each page or annotation link, containing just the list and no header/full-page wrapper, so they are nice to transclude *into* popups:
          Par.mapM_ (writeLinkBibliographyFragment am md) $ sort $ M.keys md

writeLinkBibliographyFragment :: ArchiveMetadata -> Metadata -> FilePath -> IO ()
writeLinkBibliographyFragment am md path =
  case M.lookup path md of
    Nothing -> return ()
    Just (_,_,_,_,_,_,"") -> return ()
    Just (_,_,_,_,_,_,abstract) -> do
      let self = takeWhile (/='#') path
      let selfAbsolute = "https://gwern.net" ++ self
      let (path',_) = getLinkBibLink path
      lbExists <- doesFileExist path
      let essay = head path == '/' && '.' `notElem` path
      -- TODO: this is still slow because we have to write out all the annotation link-bibs too, regardless of change. need to check for the annotation HTML fragment's timestamp, not just essay timestamps
      shouldWrite <- if essay then -- if it doesn't exist, it could be arbitrarily out of date so we default to trying to write it:
                                   if not lbExists then return True else
                                     do essayLastModified <- getModificationTime (tail (takeWhile (/='#') path) ++ ".md")
                                        lbLastModified    <- getModificationTime path'
                                        return (essayLastModified >= lbLastModified)
                      else return True
      when shouldWrite $ parseExtractCompileWrite am md path path' self selfAbsolute abstract

parseExtractCompileWrite :: ArchiveMetadata -> Metadata -> String -> FilePath -> String -> String -> String -> IO ()
parseExtractCompileWrite am md path path' self selfAbsolute abstract = do
        -- toggle between parsing the full original Markdown page, and just the annotation abstract:
        linksRaw <- if head path == '/' && '.'`notElem`path then
                      if '#' `elem` path && abstract=="" then return [] -- if it's just an empty annotation triggered by a section existing, ignore
                      else
                        extractLinksFromPage (tail (takeWhile (/='#') path) ++ ".md") -- Markdown essay
                    else return $ map T.unpack $ nubOrd $ extractLinks False (T.pack abstract) -- annotation
            -- delete self-links, such as in the ToC of scraped abstracts, or newsletters linking themselves as the first link (eg. '/newsletter/2022/05' will link to 'https://gwern.net/newsletter/2022/05' at the beginning)
        let links = filter (\l -> not (self `isPrefixOf` l || selfAbsolute `isPrefixOf` l)) linksRaw
        when (length (filter (\l -> not ("https://en.wikipedia.org/wiki/" `isPrefixOf` l))  links) >= C.mininumLinkBibliographyFragment) $
          do

             let pairs = linksToAnnotations md links
                 body = [Para [Strong [Str "Link Bibliography"], Str ":"], generateLinkBibliographyItems am pairs]
                 document = Pandoc nullMeta body
                 html = runPure $ writeHtml5String def{writerExtensions = pandocExtensions} $
                   walk typographyTransform $ convertInterwikiLinks $ walk (hasAnnotation md) document
             case html of
               Left e   -> printRed (show e)
               -- compare with the old version, and update if there are any differences:
               Right p' -> do when (path' == "") $ error ("generateLinkBibliography.hs: writeLinkBibliographyFragment: writing out failed because received empty path' from getLinkBibLink for original path: " ++ path)
                              writeUpdatedFile "link-bibliography-fragment" path' p'

generateLinkBibliographyItems :: ArchiveMetadata -> [(String,MetadataItem)] -> Block
generateLinkBibliographyItems _ [] = Para []
generateLinkBibliographyItems am items = let itemsWP = filter (\(u,_) -> "https://en.wikipedia.org/wiki/" `isPrefixOf` u) items
                                             itemsPrimary =  items \\ itemsWP
                                    in OrderedList (1, DefaultStyle, DefaultDelim)
                                      (map (generateLinkBibliographyItem am) itemsPrimary ++
                                          -- because WP links are so numerous, and so bulky, stick them into a collapsed sub-list at the end:
                                          if null itemsWP then [] else [
                                                                        [Div ("",["collapse"],[]) [
                                                                            Para [Strong [Str "Wikipedia Link Bibliography"], Str ":"],
                                                                            OrderedList (1, DefaultStyle, DefaultDelim) (map (generateLinkBibliographyItem am) itemsWP)]]]
                                      )
generateLinkBibliographyItem  :: ArchiveMetadata -> (String,MetadataItem) -> [Block]
generateLinkBibliographyItem _ (f,(t,_,_,_,_,_,""))  = -- short:
  let f'
        | "http" `isPrefixOf` f = f
        | "index" `isSuffixOf` f = takeDirectory f
        | otherwise = takeFileName f
      -- Imagine we link to a target on another Gwern.net page like </question#feynman>. It has no full annotation and never will, not even a title.
      -- So it would show up in the link-bib as merely eg. '55. `/question#feynman`'. Not very useful! Why can't it simply transclude that snippet instead?
      -- So, we do that here: if it is a local page path, has an anchor `#` in it, and does not have an annotation ("" pattern-match guarantees that),'
      -- we try to append a blockquote with the `.include-block-context` class, to make it look like the backlinks approach to transcluding the context
      -- at a glance:
      transcludeTarget = if not (isPagePath (T.pack f) && '#' `elem` f) then [] else
                           [BlockQuote [Para [Link ("", ["backlink-not", "include-block-context", "link-annotated-not"], [])
                                               [Str "[Transclude the forward-link's context]"] (T.pack f,"")]]]
      -- I skip date because files don't usually have anything better than year, and that's already encoded in the filename which is shown
  in
    let linkAttr = if "https://en.wikipedia.org/wiki/" `isPrefixOf` f then ("",["include-annotation"],[]) else ("",["id-not"],[])
    in
    if t=="" then
      Para [Link linkAttr [Code nullAttr (T.pack f')] (T.pack f, "")] : transcludeTarget
    else
      Para [Link linkAttr [RawInline (Format "HTML") (T.pack $ titlecase t)] (T.pack f, "")] : transcludeTarget
-- long items:
generateLinkBibliographyItem am (f,a) = generateAnnotationTransclusionBlock am (f,a)

-- TODO: refactor out to Query?
extractLinksFromPage :: String -> IO [String]
extractLinksFromPage "" = error "generateLinkBibliography: `extractLinksFromPage` called with an empty '' string argument—this should never happen!"
extractLinksFromPage path =
  do existsp <- doesFileExist path
     if not existsp then return [] else
                    do f <- TIO.readFile path
                       let pE = runPure $ readMarkdown def{readerExtensions=pandocExtensions} f
                       return $ case pE of
                                  Left  _ -> []
                                  -- make the list unique, but keep the original ordering
                                  Right p -> map (replace "https://gwern.net/" "/") $
                                                     filter (\l -> head l /= '#') $ -- self-links are not useful in link bibliographies
                                                     nubOrd $ map T.unpack $ extractURLs p -- TODO: maybe extract the title from the metadata for nicer formatting?

linksToAnnotations :: Metadata -> [String] -> [(String,MetadataItem)]
linksToAnnotations m = map (linkToAnnotation m)
linkToAnnotation :: Metadata -> String -> (String,MetadataItem)
linkToAnnotation m u = case M.lookup u m of
                         Just i  -> (u,i)
                         Nothing -> (u,("","","","",[],[],""))
