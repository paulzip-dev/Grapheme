/*
  Copyright (c) 2026 Paul Scott

  Unit tests for P_Grapheme (utPLSQL v3).
  Text is described by hex code points, e.g. '0065 0301' is "e" + COMBINING ACUTE ACCENT, and is built as
  VARCHAR2 (V), NVARCHAR2 (N) and CLOB (C) so that every datatype is exercised by the same expectations.
  The official Unicode conformance data is in P_UT_Grapheme_Conformance.

  Frequently used text, "sample":  a  e+U+0301  U+1F600  b   (4 graphemes, 5 code points, 6 UTF-16 units)
*/
create or replace
package P_UT_Grapheme is

  --%suite(P_Grapheme: extended grapheme clusters)

  --%context(GraphemeCount)

  --%test(ASCII, empty and null)
  procedure CountBasic;

  --%test(Combining marks, zalgo and supplementary characters)
  procedure CountCombining;

  --%test(CR LF controls)
  procedure CountControls;

  --%test(Hangul jamo and syllables)
  procedure CountHangul;

  --%test(Emoji: ZWJ sequences, modifiers, keycaps, variation selectors)
  procedure CountEmoji;

  --%test(Regional indicator flags)
  procedure CountFlags;

  --%test(Prepend, SpacingMark, Thai)
  procedure CountPrependSpacingMark;

  --%test(Indic conjuncts GB9c)
  procedure CountIndicConjuncts;

  --%test(Lone surrogates never raise)
  procedure CountLoneSurrogates;

  --%test(CLOB longer than 32767 characters)
  procedure CountLongClob;

  --%test(CLOB where a decode chunk would end inside a surrogate pair)
  procedure CountClobChunkSplitsPair;

  --%endcontext

  --%context(GraphemeAt)

  --%test(Returns the cluster)
  procedure AtReturnsCluster;

  --%test(Index 0 raises INDEX_OUT_OF_RANGE)
  --%throws(-20100)
  procedure AtZero;

  --%test(Index past the end raises INDEX_OUT_OF_RANGE)
  --%throws(-20100)
  procedure AtBeyondEnd;

  --%test(Null index raises INDEX_OUT_OF_RANGE)
  --%throws(-20100)
  procedure AtNullIndex;

  --%test(Empty text raises INDEX_OUT_OF_RANGE)
  --%throws(-20100)
  procedure AtEmptyText;

  --%test(NVARCHAR2 index past the end raises INDEX_OUT_OF_RANGE)
  --%throws(-20100)
  procedure AtBeyondEndNvarchar2;

  --%test(CLOB index past the end raises INDEX_OUT_OF_RANGE)
  --%throws(-20100)
  procedure AtBeyondEndClob;

  --%endcontext

  --%context(GraphemeSubstr)

  --%test(Start and length)
  procedure SubstrStartLength;

  --%test(Null length means to the end, long length is clamped)
  procedure SubstrToEnd;

  --%test(Nothing selected gives null)
  procedure SubstrNothing;

  --%test(Start 0 raises INDEX_OUT_OF_RANGE)
  --%throws(-20100)
  procedure SubstrStartZero;

  --%test(Negative length raises INDEX_OUT_OF_RANGE)
  --%throws(-20100)
  procedure SubstrNegativeLength;

  --%endcontext

  --%context(GraphemeTruncate)

  --%test(Never splits a cluster)
  procedure TruncateKeepsClusters;

  --%test(Zero, over-length and null limits)
  procedure TruncateLimits;

  --%test(Negative limit raises INDEX_OUT_OF_RANGE)
  --%throws(-20100)
  procedure TruncateNegative;

  --%endcontext

  --%context(GraphemeBoundaries)

  --%test(Native unit per datatype)
  procedure BoundariesNative;

  --%test(UNIT_CODEPOINT)
  procedure BoundariesCodePoint;

  --%test(UNIT_UTF16)
  procedure BoundariesUtf16;

  --%test(UNIT_BYTE: UTF-8 for VARCHAR2, UTF-16 for NVARCHAR2)
  procedure BoundariesByte;

  --%test(Empty and null text have the single boundary 1)
  procedure BoundariesEmpty;

  --%test(More than 32767 boundaries)
  procedure BoundariesVeryLong;

  --%test(Invalid unit raises INVALID_UNIT)
  --%throws(-20101)
  procedure BoundariesInvalidUnit;

  --%test(UNIT_BYTE on a CLOB raises INVALID_UNIT)
  --%throws(-20101)
  procedure BoundariesClobByte;

  --%endcontext

  --%context(IsGraphemeBoundary)

  --%test(Code point offsets)
  procedure IsBoundaryCodePoint;

  --%test(UTF-16 offsets: inside a surrogate pair is not a boundary)
  procedure IsBoundaryUtf16;

  --%test(Byte offsets: inside a multibyte character is not a boundary)
  procedure IsBoundaryByte;

  --%test(Out of range and null offsets are not boundaries)
  procedure IsBoundaryOutOfRange;

  --%test(Empty text: offset 1 is a boundary)
  procedure IsBoundaryEmpty;

  --%endcontext

  --%context(GraphemeOffset)

  --%test(Offset of each grapheme in every unit)
  procedure OffsetPerUnit;

  --%test(Index past the end raises INDEX_OUT_OF_RANGE)
  --%throws(-20100)
  procedure OffsetBeyondEnd;

  --%test(Index 0 raises INDEX_OUT_OF_RANGE)
  --%throws(-20100)
  procedure OffsetZero;

  --%endcontext

  --%context(GraphemeIterator)

  --%test(Pipelined iterator in native units)
  procedure IteratorRowsNative;

  --%test(Pipelined iterator in a requested unit)
  procedure IteratorRowsUnit;

  --%test(Empty text gives no rows)
  procedure IteratorEmpty;

  --%test(A cluster over 2000 characters raises CLUSTER_TOO_LONG)
  --%throws(-20102)
  procedure IteratorClusterTooLong;

  --%test(TY_GraphemeIterator walks the clusters)
  procedure ObjectIteratorWalks;

  --%test(TY_GraphemeIterator.Reset starts again)
  procedure ObjectIteratorReset;

  --%test(TY_GraphemeIterator.Next past the end raises)
  --%throws(-20100)
  procedure ObjectIteratorPastEnd;

  --%endcontext

end P_UT_Grapheme;
/

create or replace
package body P_UT_Grapheme is

  -- "sample": a, e + COMBINING ACUTE ACCENT, GRINNING FACE, b
  SAMPLE constant varchar2(100) := '0061 0065 0301 1F600 0062';

  function Utf16Hex(pCodePoint pls_integer) return varchar2 is
    vOffset pls_integer;
    vResult varchar2(8);
  begin
    if pCodePoint < 65536 then
      vResult := lpad(to_char(pCodePoint, 'FMXXXX'), 4, '0');
    else
      vOffset := pCodePoint - 65536;
      vResult := to_char(55296 + trunc(vOffset / 1024), 'FMXXXX') || to_char(56320 + mod(vOffset, 1024), 'FMXXXX');
    end if;
    return vResult;
  end;

  -- 'hex hex ...' of code points -> UTF-16BE hex
  function U16(pCodePoints varchar2) return varchar2 is
    vResult varchar2(32767);
    vToken  varchar2(10);
    vPos    pls_integer := 1;
  begin
    for i in 1..regexp_count(trim(pCodePoints), '\S+')
    loop
      vToken := regexp_substr(trim(pCodePoints), '\S+', 1, i);
      vResult := vResult || Utf16Hex(to_number(vToken, 'XXXXXX'));
    end loop;
    return vResult;
  end;

  function V(pCodePoints varchar2) return varchar2 is
  begin
    return utl_i18n.raw_to_char(hextoraw(U16(pCodePoints)), 'AL16UTF16');
  end;

  function N(pCodePoints varchar2) return nvarchar2 is
  begin
    return utl_i18n.raw_to_nchar(hextoraw(U16(pCodePoints)), 'AL16UTF16');
  end;

  function C(pCodePoints varchar2) return clob is
  begin
    return to_clob(V(pCodePoints));
  end;

  -- UTF-16BE hex of a VARCHAR2 or NVARCHAR2
  function Hex(pText varchar2 character set any_cs) return varchar2 is
  begin
    return rawtohex(utl_i18n.string_to_raw(pText, 'AL16UTF16'));
  end;

  function HexC(pText clob) return varchar2 is
  begin
    return Hex(dbms_lob.substr(pText, 4000, 1));
  end;

  function Csv(pOffsets CL_GraphemeOffsets) return varchar2 is
    vResult varchar2(32767);
  begin
    for i in 1..pOffsets.Count
    loop
      vResult := vResult || case when i > 1 then ',' end || pOffsets(i);
    end loop;
    return vResult;
  end;

  -- clob of a repeated code point list
  function Repeated(pCodePoints varchar2, pTimes pls_integer, pPrefix varchar2 default null) return clob is
    vResult clob;
    vUnit   varchar2(100) := V(pCodePoints);
  begin
    dbms_lob.createtemporary(vResult, True);
    if pPrefix is not null then
      dbms_lob.append(vResult, to_clob(V(pPrefix)));
    end if;
    for i in 1..pTimes
    loop
      dbms_lob.append(vResult, to_clob(vUnit));
    end loop;
    return vResult;
  end;

  ---------------------------------------------------------------------------
  -- GraphemeCount
  ---------------------------------------------------------------------------

  -- Count of a code point list, for VARCHAR2, NVARCHAR2 and CLOB
  procedure ExpectCount(pCodePoints varchar2, pExpected pls_integer) is
  begin
    ut.expect(P_Grapheme.GraphemeCount(V(pCodePoints)), 'VARCHAR2 ' || pCodePoints).to_equal(pExpected);
    ut.expect(P_Grapheme.GraphemeCount(N(pCodePoints)), 'NVARCHAR2 ' || pCodePoints).to_equal(pExpected);
    ut.expect(P_Grapheme.GraphemeCount(C(pCodePoints)), 'CLOB ' || pCodePoints).to_equal(pExpected);
  end;

  procedure CountBasic is
    vNullVarchar2  varchar2(10);
    vNullNvarchar2 nvarchar2(10);
    vNullClob      clob;
  begin
    ExpectCount('0068 0065 006C 006C 006F', 5);
    ExpectCount('0020', 1);
    ut.expect(P_Grapheme.GraphemeCount(vNullVarchar2), 'null VARCHAR2').to_equal(0);
    ut.expect(P_Grapheme.GraphemeCount(vNullNvarchar2), 'null NVARCHAR2').to_equal(0);
    ut.expect(P_Grapheme.GraphemeCount(vNullClob), 'null CLOB').to_equal(0);
    ut.expect(P_Grapheme.GraphemeCount(to_clob(empty_clob())), 'empty CLOB').to_equal(0);
    ut.expect(P_Grapheme.GraphemeCount(''), 'empty literal').to_equal(0);
  end;

  procedure CountCombining is
    vZalgo varchar2(32767) := '0061';
  begin
    ExpectCount('0065 0301', 1);                  -- e + acute
    ExpectCount('0065 0301 0302 0303', 1);        -- several marks
    ExpectCount('0065 0301 0066', 2);
    ExpectCount('0301', 1);                       -- a mark on its own
    ExpectCount('0301 0301', 1);
    ExpectCount('1F600', 1);                      -- supplementary character
    ExpectCount('1F600 1F600', 2);
    ExpectCount('0061 1F600 0062', 3);
    ExpectCount('0061 0308 1F600 0308 0062', 3);  -- marks on a supplementary character
    ExpectCount(SAMPLE, 4);
    for i in 1..300
    loop
      vZalgo := vZalgo || ' 0300';
    end loop;
    ExpectCount(vZalgo, 1);
    ExpectCount(vZalgo || ' 0062', 2);
  end;

  procedure CountControls is
  begin
    ExpectCount('000D 000A', 1);                  -- GB3
    ExpectCount('000A 000D', 2);
    ExpectCount('000D 000D', 2);
    ExpectCount('000A 000A', 2);
    ExpectCount('0061 000D 000A 0062', 3);
    ExpectCount('0061 000A 0062', 3);             -- GB4, GB5
    ExpectCount('0000 0000', 2);
    ExpectCount('000D 0301', 2);                  -- a mark does not attach to a control
    ExpectCount('0061 200B', 2);                  -- ZERO WIDTH SPACE is a control
    ExpectCount('2028 2029', 2);                  -- LINE / PARAGRAPH SEPARATOR
  end;

  procedure CountHangul is
  begin
    ExpectCount('1100 1161 11A8', 1);             -- L V T  (decomposed 각)
    ExpectCount('1100 1161', 1);
    ExpectCount('1100 1100 1161', 1);             -- L L V
    ExpectCount('AC00', 1);                       -- LV
    ExpectCount('AC00 11A8', 1);                  -- LV T
    ExpectCount('AC00 1161', 1);                  -- LV V
    ExpectCount('AC01 11A8', 1);                  -- LVT T
    ExpectCount('AC01 1161', 2);                  -- LVT V breaks
    ExpectCount('11A8 1100', 2);                  -- T L breaks
    ExpectCount('AC00 1100', 2);                  -- LV L breaks
    ExpectCount('1161 1100', 2);                  -- V L breaks
    ExpectCount('AC00 AC01', 2);                  -- two syllables
    ExpectCount('D55C AE00', 2);                  -- 한글
  end;

  procedure CountEmoji is
  begin
    ExpectCount('1F469 200D 1F680', 1);                       -- woman astronaut
    ExpectCount('1F468 200D 1F469 200D 1F467', 1);            -- family
    ExpectCount('1F468 200D 1F469 200D 1F467 200D 1F466', 1);
    ExpectCount('1F44D 1F3FD', 1);                            -- thumbs up + skin tone (Extend)
    ExpectCount('1F44D 1F3FD 1F44D', 2);
    ExpectCount('2764 FE0F', 1);                              -- heart + variation selector
    ExpectCount('0031 FE0F 20E3', 1);                         -- keycap
    ExpectCount('0023 FE0F 20E3 002A FE0F 20E3', 2);
    ExpectCount('0061 200D 1F600', 2);                        -- ZWJ only joins pictographs
    ExpectCount('1F600 200D 0061', 2);
    ExpectCount('1F600 200D 200D 1F600', 2);                  -- a second ZWJ ends the sequence
    ExpectCount('1F600 0308 200D 1F600', 1);                  -- Extend* before the ZWJ is allowed
    ExpectCount('1F600 200D 0308 1F600', 2);                  -- Extend after the ZWJ is not
    ExpectCount('1F3F4 E0067 E0062 E0065 E006E E0067 E007F', 1);  -- tag sequence (flag of England)
  end;

  procedure CountFlags is
  begin
    ExpectCount('1F1EC', 1);                                  -- a single regional indicator
    ExpectCount('1F1EC 1F1E7', 1);                            -- GB
    ExpectCount('1F1EC 1F1E7 1F1EB', 2);
    ExpectCount('1F1EC 1F1E7 1F1EB 1F1F7', 2);                -- GB FR
    ExpectCount('1F1EC 1F1E7 1F1EB 1F1F7 1F1E9', 3);
    ExpectCount('1F1EC 1F1E7 0061 1F1EB 1F1F7', 3);           -- a non-RI restarts the pairing
    ExpectCount('1F1EC 0308 1F1E7', 2);                       -- an Extend between them: the pair is not adjacent
    ExpectCount('1F1EC 1F1E7 0308 1F1EB 1F1F7', 2);           -- Extend attaches to the first flag
    ExpectCount('0061 1F1EC 1F1E7', 2);
  end;

  procedure CountPrependSpacingMark is
  begin
    ExpectCount('0600 0661', 1);                  -- Prepend + digit
    ExpectCount('0061 0600', 2);                  -- Prepend at the end of the text
    ExpectCount('0600 000D', 2);                  -- Prepend never attaches to a control
    ExpectCount('0915 093E', 1);                  -- consonant + SpacingMark (vowel sign AA)
    ExpectCount('0E01 0E33', 1);                  -- Thai KO KAI + SARA AM
    ExpectCount('0E01 0E01', 2);
  end;

  procedure CountIndicConjuncts is
  begin
    ExpectCount('0915 094D 0937', 1);             -- Devanagari KA VIRAMA SSA
    ExpectCount('0915 094D 0937 094D 092F', 1);   -- three-consonant conjunct
    ExpectCount('0915 094D 200D 0937', 1);        -- ZWJ after the virama
    ExpectCount('0915 094D 093C 0937', 1);        -- nukta after the virama (InCB=Extend)
    ExpectCount('0995 09CD 09B7', 1);             -- Bengali
    ExpectCount('0915 0937', 2);                  -- no virama
    ExpectCount('0915 094D 0061', 2);             -- virama followed by a non-consonant
    ExpectCount('0915 094D 0308 0061', 2);
    ExpectCount('0061 094D 0937', 1);             -- Unicode 16+: the Linker need not follow a consonant
  end;

  procedure CountLoneSurrogates is
    vHighThenA nvarchar2(10) := utl_raw.cast_to_nvarchar2(hextoraw('D83D0061'));
    vLowThenA  nvarchar2(10) := utl_raw.cast_to_nvarchar2(hextoraw('DE000061'));
    vHighOnly  nvarchar2(10) := utl_raw.cast_to_nvarchar2(hextoraw('0061D83D'));
  begin
    ut.expect(P_Grapheme.GraphemeCount(vHighThenA), 'high surrogate, a').to_equal(2);
    ut.expect(P_Grapheme.GraphemeCount(vLowThenA), 'low surrogate, a').to_equal(2);
    ut.expect(P_Grapheme.GraphemeCount(vHighOnly), 'a, high surrogate at the end').to_equal(2);
  end;

  procedure CountLongClob is
    vLob clob := Repeated('0061', 130000);
  begin
    ut.expect(P_Grapheme.GraphemeCount(vLob), 'a * 130000').to_equal(130000);
    ut.expect(P_Grapheme.GraphemeCount(Repeated('0065 0301', 70000)), 'e+acute * 70000').to_equal(70000);
  end;

  procedure CountClobChunkSplitsPair is
    -- 1 + 2 * n UTF-16 units: the 4000 unit decode chunk ends between the halves of a pair
    vLob clob := Repeated('1F600', 5000, '0078');
  begin
    ut.expect(P_Grapheme.GraphemeCount(vLob), 'x + 5000 emoji').to_equal(5001);
    ut.expect(HexC(P_Grapheme.GraphemeAt(vLob, 2001)), 'cluster 2001').to_equal(U16('1F600'));
  end;

  ---------------------------------------------------------------------------
  -- GraphemeAt
  ---------------------------------------------------------------------------

  procedure AtReturnsCluster is
  begin
    ut.expect(Hex(P_Grapheme.GraphemeAt(V(SAMPLE), 1)), 'V 1').to_equal(U16('0061'));
    ut.expect(Hex(P_Grapheme.GraphemeAt(V(SAMPLE), 2)), 'V 2').to_equal(U16('0065 0301'));
    ut.expect(Hex(P_Grapheme.GraphemeAt(V(SAMPLE), 3)), 'V 3').to_equal(U16('1F600'));
    ut.expect(Hex(P_Grapheme.GraphemeAt(V(SAMPLE), 4)), 'V 4').to_equal(U16('0062'));
    ut.expect(Hex(P_Grapheme.GraphemeAt(N(SAMPLE), 2)), 'N 2').to_equal(U16('0065 0301'));
    ut.expect(Hex(P_Grapheme.GraphemeAt(N(SAMPLE), 3)), 'N 3').to_equal(U16('1F600'));
    ut.expect(Hex(P_Grapheme.GraphemeAt(N(SAMPLE), 4)), 'N 4').to_equal(U16('0062'));
    ut.expect(HexC(P_Grapheme.GraphemeAt(C(SAMPLE), 2)), 'C 2').to_equal(U16('0065 0301'));
    ut.expect(HexC(P_Grapheme.GraphemeAt(C(SAMPLE), 3)), 'C 3').to_equal(U16('1F600'));
    ut.expect(HexC(P_Grapheme.GraphemeAt(C(SAMPLE), 4)), 'C 4').to_equal(U16('0062'));
    -- a whole ZWJ family is one cluster
    ut.expect(Hex(P_Grapheme.GraphemeAt(V('0061 1F468 200D 1F469 200D 1F467 0062'), 2)), 'family')
      .to_equal(U16('1F468 200D 1F469 200D 1F467'));
    ut.expect(Hex(P_Grapheme.GraphemeAt(V('000D 000A 0061'), 1)), 'CRLF').to_equal(U16('000D 000A'));
  end;

  procedure AtZero is
    vResult varchar2(100);
  begin
    vResult := P_Grapheme.GraphemeAt(V(SAMPLE), 0);
  end;

  procedure AtBeyondEnd is
    vResult varchar2(100);
  begin
    vResult := P_Grapheme.GraphemeAt(V(SAMPLE), 5);
  end;

  procedure AtNullIndex is
    vResult varchar2(100);
  begin
    vResult := P_Grapheme.GraphemeAt(V(SAMPLE), null);
  end;

  procedure AtEmptyText is
    vResult varchar2(100);
    vText   varchar2(10);
  begin
    vResult := P_Grapheme.GraphemeAt(vText, 1);
  end;

  procedure AtBeyondEndNvarchar2 is
    vResult nvarchar2(100);
  begin
    vResult := P_Grapheme.GraphemeAt(N(SAMPLE), 5);
  end;

  procedure AtBeyondEndClob is
    vResult clob;
  begin
    vResult := P_Grapheme.GraphemeAt(C(SAMPLE), 5);
  end;

  ---------------------------------------------------------------------------
  -- GraphemeSubstr
  ---------------------------------------------------------------------------

  procedure SubstrStartLength is
  begin
    ut.expect(Hex(P_Grapheme.GraphemeSubstr(V(SAMPLE), 2, 2)), 'V').to_equal(U16('0065 0301 1F600'));
    ut.expect(Hex(P_Grapheme.GraphemeSubstr(N(SAMPLE), 2, 2)), 'N').to_equal(U16('0065 0301 1F600'));
    ut.expect(HexC(P_Grapheme.GraphemeSubstr(C(SAMPLE), 2, 2)), 'C').to_equal(U16('0065 0301 1F600'));
    ut.expect(Hex(P_Grapheme.GraphemeSubstr(V(SAMPLE), 1, 1)), 'first').to_equal(U16('0061'));
    ut.expect(Hex(P_Grapheme.GraphemeSubstr(V(SAMPLE), 1, 4)), 'all').to_equal(U16(SAMPLE));
    ut.expect(Hex(P_Grapheme.GraphemeSubstr(V(SAMPLE), 4, 1)), 'last').to_equal(U16('0062'));
  end;

  procedure SubstrToEnd is
  begin
    ut.expect(Hex(P_Grapheme.GraphemeSubstr(V(SAMPLE), 3)), 'V default length').to_equal(U16('1F600 0062'));
    ut.expect(Hex(P_Grapheme.GraphemeSubstr(N(SAMPLE), 3, null)), 'N null length').to_equal(U16('1F600 0062'));
    ut.expect(HexC(P_Grapheme.GraphemeSubstr(C(SAMPLE), 3, null)), 'C null length').to_equal(U16('1F600 0062'));
    ut.expect(Hex(P_Grapheme.GraphemeSubstr(V(SAMPLE), 4, 100)), 'clamped').to_equal(U16('0062'));
    ut.expect(Hex(P_Grapheme.GraphemeSubstr(V(SAMPLE), 1, 100)), 'clamped all').to_equal(U16(SAMPLE));
  end;

  procedure SubstrNothing is
    vNullText varchar2(10);
  begin
    ut.expect(P_Grapheme.GraphemeSubstr(V(SAMPLE), 5, 1), 'past the end').to_be_null();
    ut.expect(P_Grapheme.GraphemeSubstr(V(SAMPLE), 2, 0), 'length 0').to_be_null();
    ut.expect(P_Grapheme.GraphemeSubstr(V(SAMPLE), null, 1), 'null start').to_be_null();
    ut.expect(P_Grapheme.GraphemeSubstr(vNullText, 1, 1), 'null text').to_be_null();
    ut.expect(P_Grapheme.GraphemeSubstr(N(SAMPLE), 5, 1), 'N past the end').to_be_null();
    ut.expect(P_Grapheme.GraphemeSubstr(C(SAMPLE), 5, 1) is null, 'C past the end').to_be_true();
    ut.expect(P_Grapheme.GraphemeSubstr(C(SAMPLE), 2, 0) is null, 'C length 0').to_be_true();
  end;

  procedure SubstrStartZero is
    vResult varchar2(100);
  begin
    vResult := P_Grapheme.GraphemeSubstr(V(SAMPLE), 0, 1);
  end;

  procedure SubstrNegativeLength is
    vResult varchar2(100);
  begin
    vResult := P_Grapheme.GraphemeSubstr(V(SAMPLE), 1, -1);
  end;

  ---------------------------------------------------------------------------
  -- GraphemeTruncate
  ---------------------------------------------------------------------------

  procedure TruncateKeepsClusters is
    -- "a", family (one cluster of 5 code points), "b"
    cText constant varchar2(100) := '0061 1F468 200D 1F469 200D 1F467 0062';
  begin
    ut.expect(Hex(P_Grapheme.GraphemeTruncate(V(cText), 1)), 'V 1').to_equal(U16('0061'));
    ut.expect(Hex(P_Grapheme.GraphemeTruncate(V(cText), 2)), 'V 2 keeps the whole family')
      .to_equal(U16('0061 1F468 200D 1F469 200D 1F467'));
    ut.expect(Hex(P_Grapheme.GraphemeTruncate(N(cText), 2)), 'N 2')
      .to_equal(U16('0061 1F468 200D 1F469 200D 1F467'));
    ut.expect(HexC(P_Grapheme.GraphemeTruncate(C(cText), 2)), 'C 2')
      .to_equal(U16('0061 1F468 200D 1F469 200D 1F467'));
    ut.expect(Hex(P_Grapheme.GraphemeTruncate(V(SAMPLE), 2)), 'combining mark kept').to_equal(U16('0061 0065 0301'));
    ut.expect(Hex(P_Grapheme.GraphemeTruncate(V(SAMPLE), 3)), 'supplementary kept').to_equal(U16('0061 0065 0301 1F600'));
  end;

  procedure TruncateLimits is
    vNullText varchar2(10);
  begin
    ut.expect(P_Grapheme.GraphemeTruncate(V(SAMPLE), 0), 'zero').to_be_null();
    ut.expect(Hex(P_Grapheme.GraphemeTruncate(V(SAMPLE), 100)), 'over-length').to_equal(U16(SAMPLE));
    ut.expect(Hex(P_Grapheme.GraphemeTruncate(V(SAMPLE), 4)), 'exact length').to_equal(U16(SAMPLE));
    ut.expect(Hex(P_Grapheme.GraphemeTruncate(V(SAMPLE), null)), 'null = no limit').to_equal(U16(SAMPLE));
    ut.expect(P_Grapheme.GraphemeTruncate(vNullText, 3), 'null text').to_be_null();
    ut.expect(HexC(P_Grapheme.GraphemeTruncate(C(SAMPLE), 100)), 'C over-length').to_equal(U16(SAMPLE));
  end;

  procedure TruncateNegative is
    vResult varchar2(100);
  begin
    vResult := P_Grapheme.GraphemeTruncate(V(SAMPLE), -1);
  end;

  ---------------------------------------------------------------------------
  -- GraphemeBoundaries
  ---------------------------------------------------------------------------

  procedure BoundariesNative is
  begin
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(V(SAMPLE))), 'VARCHAR2: code points').to_equal('1,2,4,5,6');
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(N(SAMPLE))), 'NVARCHAR2: UTF-16 units').to_equal('1,2,4,6,7');
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(C(SAMPLE))), 'CLOB: UTF-16 units').to_equal('1,2,4,6,7');
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(V(SAMPLE), P_Grapheme.UNIT_NATIVE)), 'explicit native')
      .to_equal('1,2,4,5,6');
  end;

  procedure BoundariesCodePoint is
  begin
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(V(SAMPLE), P_Grapheme.UNIT_CODEPOINT)), 'V').to_equal('1,2,4,5,6');
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(N(SAMPLE), P_Grapheme.UNIT_CODEPOINT)), 'N').to_equal('1,2,4,5,6');
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(C(SAMPLE), P_Grapheme.UNIT_CODEPOINT)), 'C').to_equal('1,2,4,5,6');
  end;

  procedure BoundariesUtf16 is
  begin
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(V(SAMPLE), P_Grapheme.UNIT_UTF16)), 'V').to_equal('1,2,4,6,7');
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(N(SAMPLE), P_Grapheme.UNIT_UTF16)), 'N').to_equal('1,2,4,6,7');
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(C(SAMPLE), P_Grapheme.UNIT_UTF16)), 'C').to_equal('1,2,4,6,7');
  end;

  procedure BoundariesByte is
  begin
    -- UTF-8: a=1, e=1, U+0301=2, U+1F600=4, b=1
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(V(SAMPLE), P_Grapheme.UNIT_BYTE)), 'V UTF-8').to_equal('1,2,5,9,10');
    -- UTF-16: 2 bytes per unit
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(N(SAMPLE), P_Grapheme.UNIT_BYTE)), 'N UTF-16').to_equal('1,3,7,11,13');
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(V('00E9 20AC'), P_Grapheme.UNIT_BYTE)), 'U+00E9 is 2 bytes, euro 3')
      .to_equal('1,3,6');
  end;

  procedure BoundariesEmpty is
    vNullVarchar2 varchar2(10);
    vNullClob     clob;
  begin
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(vNullVarchar2)), 'null VARCHAR2').to_equal('1');
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(vNullClob)), 'null CLOB').to_equal('1');
    ut.expect(Csv(P_Grapheme.GraphemeBoundaries(vNullVarchar2, P_Grapheme.UNIT_BYTE)), 'null, bytes').to_equal('1');
  end;

  procedure BoundariesVeryLong is
    vLob clob := Repeated('0061', 40000);
  begin
    -- sys.ODCINumberList would overflow at 32767 elements
    ut.expect(P_Grapheme.GraphemeBoundaries(vLob).Count, 'elements').to_equal(40001);
    ut.expect(P_Grapheme.GraphemeBoundaries(vLob)(40001), 'end of text').to_equal(40001);
  end;

  procedure BoundariesInvalidUnit is
    vResult CL_GraphemeOffsets;
  begin
    vResult := P_Grapheme.GraphemeBoundaries(V(SAMPLE), 9);
  end;

  procedure BoundariesClobByte is
    vResult CL_GraphemeOffsets;
  begin
    vResult := P_Grapheme.GraphemeBoundaries(C(SAMPLE), P_Grapheme.UNIT_BYTE);
  end;

  ---------------------------------------------------------------------------
  -- IsGraphemeBoundary
  ---------------------------------------------------------------------------

  procedure IsBoundaryCodePoint is
    vNative boolean;
  begin
    -- boundaries at 1,2,4,5 and the end 6; 3 is inside "e + acute"
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 1, P_Grapheme.UNIT_CODEPOINT), 'start').to_be_true();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 2, P_Grapheme.UNIT_CODEPOINT), '2').to_be_true();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 3, P_Grapheme.UNIT_CODEPOINT), 'inside a cluster').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 4, P_Grapheme.UNIT_CODEPOINT), '4').to_be_true();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 6, P_Grapheme.UNIT_CODEPOINT), 'end of text').to_be_true();
    ut.expect(P_Grapheme.IsGraphemeBoundary(N(SAMPLE), 3, P_Grapheme.UNIT_CODEPOINT), 'N inside a cluster').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(N(SAMPLE), 4, P_Grapheme.UNIT_CODEPOINT), 'N 4').to_be_true();
    ut.expect(P_Grapheme.IsGraphemeBoundary(C(SAMPLE), 3, P_Grapheme.UNIT_CODEPOINT), 'C inside a cluster').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(C(SAMPLE), 4, P_Grapheme.UNIT_CODEPOINT), 'C 4').to_be_true();
    -- the default unit is native: code points for VARCHAR2
    vNative := P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 5);
    ut.expect(vNative, 'native VARCHAR2 5').to_be_true();
  end;

  procedure IsBoundaryUtf16 is
  begin
    -- 1,2,4,6 and end 7: 5 is inside the surrogate pair of U+1F600, 3 inside "e + acute"
    ut.expect(P_Grapheme.IsGraphemeBoundary(N(SAMPLE), 4), 'N native 4').to_be_true();
    ut.expect(P_Grapheme.IsGraphemeBoundary(N(SAMPLE), 5), 'N native 5, inside a pair').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(N(SAMPLE), 6), 'N native 6').to_be_true();
    ut.expect(P_Grapheme.IsGraphemeBoundary(N(SAMPLE), 7), 'N native end').to_be_true();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 5, P_Grapheme.UNIT_UTF16), 'V 5').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 6, P_Grapheme.UNIT_UTF16), 'V 6').to_be_true();
    ut.expect(P_Grapheme.IsGraphemeBoundary(C(SAMPLE), 5), 'C native 5').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(C(SAMPLE), 6), 'C native 6').to_be_true();
  end;

  procedure IsBoundaryByte is
  begin
    -- UTF-8 boundaries 1,2,5,9 and end 10; 3 and 4 are inside U+0301, 6..8 inside U+1F600
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 2, P_Grapheme.UNIT_BYTE), 'V 2').to_be_true();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 3, P_Grapheme.UNIT_BYTE), 'V 3, start of the mark').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 4, P_Grapheme.UNIT_BYTE), 'V 4, inside the mark').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 5, P_Grapheme.UNIT_BYTE), 'V 5').to_be_true();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 7, P_Grapheme.UNIT_BYTE), 'V 7, inside the emoji').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 10, P_Grapheme.UNIT_BYTE), 'V end').to_be_true();
    -- UTF-16 boundaries 1,3,7,11 and end 13
    ut.expect(P_Grapheme.IsGraphemeBoundary(N(SAMPLE), 3, P_Grapheme.UNIT_BYTE), 'N 3').to_be_true();
    ut.expect(P_Grapheme.IsGraphemeBoundary(N(SAMPLE), 4, P_Grapheme.UNIT_BYTE), 'N 4, inside a unit').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(N(SAMPLE), 9, P_Grapheme.UNIT_BYTE), 'N 9, inside the pair').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(N(SAMPLE), 13, P_Grapheme.UNIT_BYTE), 'N end').to_be_true();
  end;

  procedure IsBoundaryOutOfRange is
  begin
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 0), 'zero').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), -3), 'negative').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 7), 'past the end').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), null), 'null').to_be_false();
    ut.expect(P_Grapheme.IsGraphemeBoundary(V(SAMPLE), 2.5), 'fraction').to_be_false();
  end;

  procedure IsBoundaryEmpty is
    vNullVarchar2 varchar2(10);
  begin
    ut.expect(P_Grapheme.IsGraphemeBoundary(vNullVarchar2, 1), 'offset 1').to_be_true();
    ut.expect(P_Grapheme.IsGraphemeBoundary(vNullVarchar2, 2), 'offset 2').to_be_false();
  end;

  ---------------------------------------------------------------------------
  -- GraphemeOffset
  ---------------------------------------------------------------------------

  procedure OffsetPerUnit is
  begin
    -- native
    ut.expect(P_Grapheme.GraphemeOffset(V(SAMPLE), 3), 'V native 3').to_equal(4);
    ut.expect(P_Grapheme.GraphemeOffset(N(SAMPLE), 3), 'N native 3').to_equal(4);
    ut.expect(P_Grapheme.GraphemeOffset(N(SAMPLE), 4), 'N native 4').to_equal(6);
    ut.expect(P_Grapheme.GraphemeOffset(C(SAMPLE), 4), 'C native 4').to_equal(6);
    -- code points
    ut.expect(P_Grapheme.GraphemeOffset(N(SAMPLE), 4, P_Grapheme.UNIT_CODEPOINT), 'N cp 4').to_equal(5);
    ut.expect(P_Grapheme.GraphemeOffset(C(SAMPLE), 4, P_Grapheme.UNIT_CODEPOINT), 'C cp 4').to_equal(5);
    -- UTF-16
    ut.expect(P_Grapheme.GraphemeOffset(V(SAMPLE), 4, P_Grapheme.UNIT_UTF16), 'V utf16 4').to_equal(6);
    ut.expect(P_Grapheme.GraphemeOffset(V(SAMPLE), 1, P_Grapheme.UNIT_UTF16), 'V utf16 1').to_equal(1);
    -- bytes
    ut.expect(P_Grapheme.GraphemeOffset(V(SAMPLE), 3, P_Grapheme.UNIT_BYTE), 'V byte 3').to_equal(5);
    ut.expect(P_Grapheme.GraphemeOffset(V(SAMPLE), 4, P_Grapheme.UNIT_BYTE), 'V byte 4').to_equal(9);
    ut.expect(P_Grapheme.GraphemeOffset(N(SAMPLE), 4, P_Grapheme.UNIT_BYTE), 'N byte 4').to_equal(11);
    -- the offset is usable with SUBSTR
    ut.expect(substr(V(SAMPLE), P_Grapheme.GraphemeOffset(V(SAMPLE), 3), 1) = V('1F600'), 'SUBSTR on VARCHAR2')
      .to_be_true();
    ut.expect(substr(N(SAMPLE), P_Grapheme.GraphemeOffset(N(SAMPLE), 4), 1) = N('0062'), 'SUBSTR on NVARCHAR2')
      .to_be_true();
    ut.expect(
        substrb(V(SAMPLE), P_Grapheme.GraphemeOffset(V(SAMPLE), 3, P_Grapheme.UNIT_BYTE), 4) = V('1F600')
      , 'SUBSTRB on VARCHAR2'
      ).to_be_true();
  end;

  procedure OffsetBeyondEnd is
    vResult integer;
  begin
    vResult := P_Grapheme.GraphemeOffset(V(SAMPLE), 5);
  end;

  procedure OffsetZero is
    vResult integer;
  begin
    vResult := P_Grapheme.GraphemeOffset(V(SAMPLE), 0);
  end;

  ---------------------------------------------------------------------------
  -- GraphemeIterator
  ---------------------------------------------------------------------------

  -- 'idx:start+length:hex;...' of the pipelined iterator
  function RowsOf(pText varchar2 character set any_cs, pUnit pls_integer default 0) return varchar2 is
    vResult varchar2(4000);
  begin
    for rec in (
      select IDX, START_POS, LENGTH, TEXT
      from table(P_Grapheme.GraphemeIterator(pText, pUnit))
      order by IDX
    )
    loop
      vResult := vResult || rec.IDX || ':' || rec.START_POS || '+' || rec.LENGTH || ':' || Hex(rec.TEXT) || ';';
    end loop;
    return vResult;
  end;

  function RowsOfClob(pText clob, pUnit pls_integer default 0) return varchar2 is
    vResult varchar2(4000);
  begin
    for rec in (
      select IDX, START_POS, LENGTH, TEXT
      from table(P_Grapheme.GraphemeIterator(pText, pUnit))
      order by IDX
    )
    loop
      vResult := vResult || rec.IDX || ':' || rec.START_POS || '+' || rec.LENGTH || ':' || Hex(rec.TEXT) || ';';
    end loop;
    return vResult;
  end;

  procedure IteratorRowsNative is
  begin
    ut.expect(RowsOf(V(SAMPLE)), 'VARCHAR2: code points')
      .to_equal('1:1+1:0061;2:2+2:00650301;3:4+1:D83DDE00;4:5+1:0062;');
    ut.expect(RowsOf(N(SAMPLE)), 'NVARCHAR2: UTF-16 units')
      .to_equal('1:1+1:0061;2:2+2:00650301;3:4+2:D83DDE00;4:6+1:0062;');
    ut.expect(RowsOfClob(C(SAMPLE)), 'CLOB: UTF-16 units')
      .to_equal('1:1+1:0061;2:2+2:00650301;3:4+2:D83DDE00;4:6+1:0062;');
  end;

  procedure IteratorRowsUnit is
  begin
    ut.expect(RowsOf(V(SAMPLE), P_Grapheme.UNIT_BYTE), 'VARCHAR2 bytes')
      .to_equal('1:1+1:0061;2:2+3:00650301;3:5+4:D83DDE00;4:9+1:0062;');
    ut.expect(RowsOf(N(SAMPLE), P_Grapheme.UNIT_CODEPOINT), 'NVARCHAR2 code points')
      .to_equal('1:1+1:0061;2:2+2:00650301;3:4+1:D83DDE00;4:5+1:0062;');
    ut.expect(RowsOf(N(SAMPLE), P_Grapheme.UNIT_BYTE), 'NVARCHAR2 bytes')
      .to_equal('1:1+2:0061;2:3+4:00650301;3:7+4:D83DDE00;4:11+2:0062;');
    ut.expect(RowsOfClob(C(SAMPLE), P_Grapheme.UNIT_CODEPOINT), 'CLOB code points')
      .to_equal('1:1+1:0061;2:2+2:00650301;3:4+1:D83DDE00;4:5+1:0062;');
  end;

  procedure IteratorEmpty is
    vNullVarchar2 varchar2(10);
    vNullClob     clob;
  begin
    ut.expect(RowsOf(vNullVarchar2), 'VARCHAR2').to_be_null();
    ut.expect(RowsOfClob(vNullClob), 'CLOB').to_be_null();
  end;

  procedure IteratorClusterTooLong is
    vRows varchar2(4000);
  begin
    -- 'a' followed by 2100 combining marks is a single cluster
    vRows := RowsOfClob(Repeated('0300', 2100, '0061'));
  end;

  procedure ObjectIteratorWalks is
    vIterator TY_GraphemeIterator := TY_GraphemeIterator.New(N(SAMPLE));
    vGrapheme TY_Grapheme;
    vResult   varchar2(4000);
  begin
    while vIterator.HasNext
    loop
      vGrapheme := vIterator.Next;
      vResult := vResult || vGrapheme.IDX || ':' || vGrapheme.START_POS || '+' || vGrapheme.LENGTH || ';';
    end loop;
    ut.expect(vResult, 'NVARCHAR2').to_equal('1:1+1;2:2+2;3:4+2;4:6+1;');
    vIterator := TY_GraphemeIterator.New(V(SAMPLE), P_Grapheme.UNIT_UTF16);
    vResult := null;
    while vIterator.HasNext
    loop
      vGrapheme := vIterator.Next;
      vResult := vResult || vGrapheme.IDX || ':' || vGrapheme.START_POS || '+' || vGrapheme.LENGTH || ';';
    end loop;
    ut.expect(vResult, 'VARCHAR2 in UTF-16 units').to_equal('1:1+1;2:2+2;3:4+2;4:6+1;');
    vIterator := TY_GraphemeIterator.New(C(SAMPLE));
    ut.expect(vIterator.Graphemes.Count, 'CLOB').to_equal(4);
  end;

  procedure ObjectIteratorReset is
    vIterator TY_GraphemeIterator := TY_GraphemeIterator.New(V(SAMPLE));
    vGrapheme TY_Grapheme;
  begin
    vGrapheme := vIterator.Next;
    vGrapheme := vIterator.Next;
    ut.expect(vGrapheme.IDX, 'second').to_equal(2);
    vIterator.Reset;
    vGrapheme := vIterator.Next;
    ut.expect(vGrapheme.IDX, 'first again').to_equal(1);
  end;

  procedure ObjectIteratorPastEnd is
    vIterator TY_GraphemeIterator := TY_GraphemeIterator.New(V('0061'));
    vGrapheme TY_Grapheme;
  begin
    vGrapheme := vIterator.Next;
    vGrapheme := vIterator.Next;
  end;

end P_UT_Grapheme;
/
