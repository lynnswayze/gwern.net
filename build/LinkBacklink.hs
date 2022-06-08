{- LinkBacklink.hs: utility functions for working with the backlinks database.
Author: Gwern Branwen
Date: 2022-02-26
When:  Time-stamp: "2022-06-07 22:52:09 gwern"
License: CC-0

This is the inverse to Query: Query extracts hyperlinks within a Pandoc document which point 'out' or 'forward',
which is the usual simple unidirectional form of a hyperlink. Backlinks are the reverse: all documents which
link *to* the current one. As a global property over all documents, they cannot be computed locally or easily.
We generate them inside the `generateBacklinks.hs` executable and store them in a database.
(Most of the complexity is inside `generateBacklinks.hs` in dealing with what files to parse, what to filter out,
how to write out the HTML snippets used to provide 'backlinks' links as gwern.net popups, etc.)

This module provides helper functions for reading & writing the backlinks database.
Because every used link necessarily has a backlink (the document in which it is used), the backlinks database
is also a convenient way to get a list of all URLs. -}

{-# LANGUAGE OverloadedStrings #-}
module LinkBacklink (getBackLink, getSimilarLink, Backlinks, readBacklinksDB, writeBacklinksDB) where

import Data.List (sort)
import qualified Data.Map.Strict as M (empty, fromList, toList, Map) -- fromListWith,
import qualified Data.Text as T (pack, unpack, Text)
import Data.Text.IO as TIO (readFile)
import Text.Read (readMaybe)
import Network.HTTP (urlEncode)
import Text.Show.Pretty (ppShow)
import System.Directory (doesFileExist)

import Utils (writeUpdatedFile)

type Backlinks = M.Map T.Text [T.Text]

readBacklinksDB :: IO Backlinks
readBacklinksDB = do exists <- doesFileExist "metadata/backlinks.hs"
                     bll <- if exists then TIO.readFile "metadata/backlinks.hs" else return ""
                     if bll=="" then return M.empty else
                       let bllM = readMaybe (T.unpack bll) :: Maybe [(T.Text,[T.Text])]
                       in case bllM of
                         Nothing   -> error ("Failed to parse backlinks.hs; read string: " ++ show bll)
                         Just bldb -> return $ M.fromList bldb
writeBacklinksDB :: Backlinks -> IO ()
writeBacklinksDB bldb = do let bll = M.toList bldb :: [(T.Text,[T.Text])]
                           let bll' = sort $ map (\(a,b) -> (T.unpack a, sort $ map T.unpack b)) bll
                           writeUpdatedFile "hakyll-backlinks" "metadata/backlinks.hs" (T.pack $ ppShow bll')

getXLink :: String -> FilePath -> IO FilePath
getXLink linkType p = do
                   let linkRaw = "/metadata/annotations/"++linkType++"/" ++
                                                                   urlEncode (p++".html")
                   linkExists <- doesFileExist $ tail linkRaw
                   -- create the doubly-URL-escaped version which decodes to the singly-escaped on-disk version (eg. `/metadata/annotations/$LINKTYPE/%252Fdocs%252Frl%252Findex.html` is how it should be in the final HTML href, but on disk it's only `metadata/annotations/$LINKTYPE/%2Fdocs%2Frl%2Findex.html`)
                   let link' = if not linkExists then "" else "/metadata/annotations/"++linkType++"/" ++
                         urlEncode (concatMap (\t -> if t=='/' || t==':' || t=='=' || t=='?' || t=='%' || t=='&' || t=='#' || t=='(' || t==')' || t=='+' then urlEncode [t] else [t]) (p++".html"))
                   return link'
getBackLink, getSimilarLink :: FilePath -> IO FilePath
getBackLink    = getXLink "backlinks"
getSimilarLink = getXLink "similars"

----------------------

-- type Forwardlinks = M.Map T.Text [T.Text]
-- convertBacklinksToForwardlinks :: Backlinks -> Forwardlinks
-- convertBacklinksToForwardlinks = M.fromListWith (++) . convertBacklinks

-- convertBacklinks :: Backlinks -> [(T.Text,[T.Text])]
-- convertBacklinks = reverseList . M.toList
--   where reverseList :: [(a,[b])] -> [(b,[a])]
--         reverseList = concatMap (\(a,bs) -> zip bs [[a]])
