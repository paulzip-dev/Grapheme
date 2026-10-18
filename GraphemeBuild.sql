/*
  Builds P_Grapheme and its types. Run as a script from any directory (@@ resolves paths relative to this file):

    @GraphemeBuild.sql
*/
@@GraphemeTypes.sql
@@P_Grapheme.sql

-- The iterator body calls P_Grapheme, so it can only compile cleanly once the package exists
alter type TY_GraphemeIterator compile body;
