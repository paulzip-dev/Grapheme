/*
  Builds the utPLSQL test packages. Requires utPLSQL v3 and a built P_Grapheme (see GraphemeBuild.sql).
  Run as a script from any directory (@@ resolves paths relative to this file):

    @BuildUnitTests.sql

  Then run the tests:

    exec ut.run('P_UT_Grapheme');
    exec ut.run('P_UT_Grapheme_Conformance');
*/
@@P_UT_Grapheme.sql
@@P_UT_Grapheme_Conformance.sql
