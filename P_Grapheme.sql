/*
  Copyright (c) 2026 Paul Scott

  P_Grapheme - Unicode Standard Annex #29 extended grapheme clusters.

  Supports VARCHAR2 (database character set, assumed AL32UTF8), NVARCHAR2 (national character set, assumed
  AL16UTF16; legacy UCS-2 data is a subset) and CLOB/NCLOB (an NCLOB argument converts implicitly to CLOB).

  Positions
  ---------
  Grapheme indexes (pIndex, pStart, pLength, pMaxLength, results of GraphemeCount) are always 1-based
  grapheme clusters.

  Offsets into the encoded string (GraphemeBoundaries, IsGraphemeBoundary, GraphemeOffset and the
  START_POS/LENGTH of GraphemeIterator) are 1-based and expressed in an explicit unit, pUnit:

    UNIT_NATIVE     (default) the unit the SQL SUBSTR/INSTR/LENGTH functions use for that datatype, so the
                    result can be fed straight into SUBSTR:
                      VARCHAR2  code points       (AL32UTF8)
                      NVARCHAR2 UTF-16 code units (AL16UTF16)
                      CLOB      UTF-16 code units (CLOB storage is UCS-2 whatever the database character set)
    UNIT_CODEPOINT  Unicode code points (true code point positions for every datatype)
    UNIT_UTF16      UTF-16 code units: a supplementary character (e.g. most emoji) counts 2
                    (Java / JavaScript / .NET string indexes, DBMS_LOB offsets)
    UNIT_BYTE       bytes in the string's own encoding: UTF-8 for VARCHAR2, UTF-16 for NVARCHAR2
                    (SUBSTRB). Not available for CLOB, which has no byte addressing.

  The returned offsets of GraphemeBoundaries have one more element than there are clusters: the final element is
  the position just past the end of the text.

  Conventions
  -----------
  - A null or empty text has 0 graphemes.
  - Lone surrogates and other malformed data never raise; a lone surrogate is treated as a control character.
  - Unicode data version: see UNICODE_VERSION.
*/
create or replace
package P_Grapheme is

  UNICODE_VERSION constant varchar2(20) := '18.0.0';

  UNIT_NATIVE    constant pls_integer := 0;
  UNIT_CODEPOINT constant pls_integer := 1;
  UNIT_UTF16     constant pls_integer := 2;
  UNIT_BYTE      constant pls_integer := 3;

  -- Error numbers raised by this package
  C_INDEX_OUT_OF_RANGE constant integer := -20100;
  C_INVALID_UNIT       constant integer := -20101;
  C_CLUSTER_TOO_LONG   constant integer := -20102;

  -- A grapheme index (or length) is outside the text
  INDEX_OUT_OF_RANGE exception;
  pragma exception_init(INDEX_OUT_OF_RANGE, C_INDEX_OUT_OF_RANGE);

  -- pUnit is not a UNIT_ constant, or is not supported for the datatype
  INVALID_UNIT exception;
  pragma exception_init(INVALID_UNIT, C_INVALID_UNIT);

  -- A cluster is longer than TY_Grapheme.TEXT can hold (2000 characters)
  CLUSTER_TOO_LONG exception;
  pragma exception_init(CLUSTER_TOO_LONG, C_CLUSTER_TOO_LONG);

  -- Number of extended grapheme clusters
  function GraphemeCount(pText varchar2 character set any_cs) return integer;
  function GraphemeCount(pText clob) return integer;

  -- The cluster at grapheme index pIndex. Raises INDEX_OUT_OF_RANGE unless 1 <= pIndex <= GraphemeCount.
  function GraphemeAt(
             pText  varchar2 character set any_cs
           , pIndex integer
           ) return varchar2 character set pText%charset;
  function GraphemeAt(pText clob, pIndex integer) return clob;

  /*
    pLength clusters starting at grapheme index pStart (like SUBSTR).
    pLength null = to the end; a pLength past the end is clamped; pStart past the end or pLength 0 gives null.
    pStart < 1 or pLength < 0 raises INDEX_OUT_OF_RANGE. A null pStart gives null.
  */
  function GraphemeSubstr(
             pText   varchar2 character set any_cs
           , pStart  integer
           , pLength integer default null
           ) return varchar2 character set pText%charset;
  function GraphemeSubstr(pText clob, pStart integer, pLength integer default null) return clob;

  -- At most pMaxLength clusters from the start, never splitting a cluster. Null pMaxLength = no limit.
  function GraphemeTruncate(
             pText      varchar2 character set any_cs
           , pMaxLength integer
           ) return varchar2 character set pText%charset;
  function GraphemeTruncate(pText clob, pMaxLength integer) return clob;

  -- Start offset of every cluster, plus the offset just past the end of the text
  function GraphemeBoundaries(
             pText varchar2 character set any_cs
           , pUnit pls_integer default UNIT_NATIVE
           ) return CL_GraphemeOffsets;
  function GraphemeBoundaries(pText clob, pUnit pls_integer default UNIT_NATIVE) return CL_GraphemeOffsets;

  -- True if pOffset is the start of a cluster or the position just past the end of the text
  function IsGraphemeBoundary(
             pText   varchar2 character set any_cs
           , pOffset integer
           , pUnit   pls_integer default UNIT_NATIVE
           ) return boolean;
  function IsGraphemeBoundary(pText clob, pOffset integer, pUnit pls_integer default UNIT_NATIVE) return boolean;

  -- Offset at which the cluster at grapheme index pIndex starts. Raises INDEX_OUT_OF_RANGE like GraphemeAt.
  function GraphemeOffset(
             pText  varchar2 character set any_cs
           , pIndex integer
           , pUnit  pls_integer default UNIT_NATIVE
           ) return integer;
  function GraphemeOffset(pText clob, pIndex integer, pUnit pls_integer default UNIT_NATIVE) return integer;

  /*
    One row per cluster:  select * from table(P_Grapheme.GraphemeIterator(pText))
    START_POS and LENGTH are in pUnit. Raises CLUSTER_TOO_LONG for a cluster over 2000 characters.
    For procedural code see TY_GraphemeIterator.
  */
  function GraphemeIterator(
             pText varchar2 character set any_cs
           , pUnit pls_integer default UNIT_NATIVE
           ) return CL_GraphemeList pipelined;
  function GraphemeIterator(pText clob, pUnit pls_integer default UNIT_NATIVE) return CL_GraphemeList pipelined;

  -- Same rows as GraphemeIterator as a plain collection (used by TY_GraphemeIterator)
  function GraphemeList(
             pText varchar2 character set any_cs
           , pUnit pls_integer default UNIT_NATIVE
           ) return CL_GraphemeList;
  function GraphemeList(pText clob, pUnit pls_integer default UNIT_NATIVE) return CL_GraphemeList;

  /*
    One row per code point, each tagged with the grapheme cluster it belongs to:
      select * from table(P_Grapheme.CodePoints(pText))
    Breaks a cluster such as a ZWJ emoji sequence into its parts.
  */
  function CodePoints(pText varchar2 character set any_cs) return CL_CodePointList pipelined;
  function CodePoints(pText clob) return CL_CodePointList pipelined;

end P_Grapheme;
/

create or replace
package body P_Grapheme is

  -- Datatype of the text being processed; decides the native unit and the byte width of a code point
  KIND_CHAR  constant pls_integer := 1;  -- VARCHAR2, database character set
  KIND_NCHAR constant pls_integer := 2;  -- NVARCHAR2, national character set
  KIND_LOB   constant pls_integer := 3;  -- CLOB

  -- Text is decoded this many characters (or UTF-16 units for a CLOB) at a time
  CHUNK_SIZE constant pls_integer := 4000;

  -- A cluster must fit TY_Grapheme.TEXT
  MAX_CLUSTER_LENGTH constant pls_integer := 2000;

  -- UTF-16 surrogate ranges
  HIGH_SURROGATE_FIRST constant pls_integer := 55296;   --   D800
  HIGH_SURROGATE_LAST  constant pls_integer := 56319;   --   DBFF
  LOW_SURROGATE_FIRST  constant pls_integer := 56320;   --   DC00
  LOW_SURROGATE_LAST   constant pls_integer := 57343;   --   DFFF
  SUPPLEMENTARY_FIRST  constant pls_integer := 65536;   --  10000
  MAX_CODE_POINT       constant pls_integer := 1114111; -- 10FFFF

  /*
    Packed Unicode property per code point (see Tools/GenerateGraphemeData.py):
      bits 0-3  Grapheme_Cluster_Break, bit 4 Extended_Pictographic, bits 5-6 Indic_Conjunct_Break
  */
  GCB_CR           constant pls_integer := 1;
  GCB_LF           constant pls_integer := 2;
  GCB_CONTROL      constant pls_integer := 3;
  GCB_EXTEND       constant pls_integer := 4;
  GCB_ZWJ          constant pls_integer := 5;
  GCB_RI           constant pls_integer := 6;
  GCB_PREPEND      constant pls_integer := 7;
  GCB_SPACING_MARK constant pls_integer := 8;
  GCB_L            constant pls_integer := 9;
  GCB_V            constant pls_integer := 10;
  GCB_T            constant pls_integer := 11;
  GCB_LV           constant pls_integer := 12;
  GCB_LVT          constant pls_integer := 13;

  INCB_CONSONANT constant pls_integer := 1;
  INCB_LINKER    constant pls_integer := 2;
  INCB_EXTEND    constant pls_integer := 3;

  -- Code points below this are looked up directly rather than by binary search
  LOW_LIMIT constant pls_integer := 768;

  type TIntList is table of pls_integer index by pls_integer;

  -- A decoded text: its code points and where each cluster starts (as a code point index)
  type TScan is record (
    CodePoints TIntList
  , CpCount    pls_integer
  , Starts     TIntList  -- Starts(Graphemes + 1) = CpCount + 1
  , Graphemes  pls_integer
  );

  -- Run-length encoded property table: code points gRunStart(i) .. gRunStart(i + 1) - 1 have value gRunValue(i)
  gRunStart TIntList;
  gRunValue TIntList;
  gRunCount pls_integer := 0;
  gLow      TIntList;

  -- Run containing the most recent lookup (text is mostly sequential within one script)
  gCacheFirst pls_integer := 0;
  gCacheLast  pls_integer := -1;
  gCacheValue pls_integer := 0;

  -- DBMS_LOB.SUBSTR chunk starts (or sometimes ends) between the two halves of a surrogate pair
  LOB_AMOUNT_NOT_ON_BOUNDARY exception;
  pragma exception_init(LOB_AMOUNT_NOT_ON_BOUNDARY, -22831);
  LOB_AMOUNT_ZERO_ON_WRITE exception;
  pragma exception_init(LOB_AMOUNT_ZERO_ON_WRITE, -22923);

  ---------------------------------------------------------------------------
  -- Unicode property table
  ---------------------------------------------------------------------------

  -- Appends runs from 'start=value,start=value,...' (hex)
  procedure AddRuns(pData varchar2) is
    vPos    pls_integer := 1;
    vComma  pls_integer;
    vEquals pls_integer;
  begin
    while vPos <= length(pData)
    loop
      vComma := instr(pData, ',', vPos);
      if vComma = 0 then
        vComma := length(pData) + 1;
      end if;
      vEquals := instr(pData, '=', vPos);
      gRunCount := gRunCount + 1;
      gRunStart(gRunCount) := to_number(substr(pData, vPos, vEquals - vPos), 'XXXXXX');
      gRunValue(gRunCount) := to_number(substr(pData, vEquals + 1, vComma - vEquals - 1), 'XX');
      vPos := vComma + 1;
    end loop;
  end;

  procedure BuildLowTable is
    vRun pls_integer := 1;
  begin
    for vCodePoint in 0..LOW_LIMIT - 1
    loop
      while vRun < gRunCount and gRunStart(vRun + 1) <= vCodePoint
      loop
        vRun := vRun + 1;
      end loop;
      gLow(vCodePoint) := gRunValue(vRun);
    end loop;
  end;

  -- Packed property of a code point
  function PropertyOf(pCodePoint pls_integer) return pls_integer is
    vLow    pls_integer;
    vHigh   pls_integer;
    vMiddle pls_integer;
    vResult pls_integer;
  begin
    if pCodePoint < LOW_LIMIT then
      vResult := gLow(pCodePoint);
    elsif pCodePoint between gCacheFirst and gCacheLast then
      vResult := gCacheValue;
    else
      -- last run starting at or before pCodePoint
      vLow := 1;
      vHigh := gRunCount;
      while vLow < vHigh
      loop
        vMiddle := trunc((vLow + vHigh + 1) / 2);
        if gRunStart(vMiddle) <= pCodePoint then
          vLow := vMiddle;
        else
          vHigh := vMiddle - 1;
        end if;
      end loop;
      gCacheFirst := gRunStart(vLow);
      if vLow < gRunCount then
        gCacheLast := gRunStart(vLow + 1) - 1;
      else
        gCacheLast := MAX_CODE_POINT;
      end if;
      gCacheValue := gRunValue(vLow);
      vResult := gCacheValue;
    end if;
    return vResult;
  end;

  ---------------------------------------------------------------------------
  -- Decoding: text -> code points
  ---------------------------------------------------------------------------

  procedure AddCodePoint(pScan in out nocopy TScan, pCodePoint pls_integer) is
  begin
    pScan.CpCount := pScan.CpCount + 1;
    pScan.CodePoints(pScan.CpCount) := pCodePoint;
  end;

  /*
    Appends the code points of a UTF-16BE RAW. pPendingHigh carries a high surrogate whose partner may be in the
    next chunk (0 = none). A surrogate without a partner is kept as is.
  */
  procedure AddUtf16(pScan in out nocopy TScan, pUtf16 raw, pPendingHigh in out pls_integer) is
    vHex  varchar2(32767) := rawtohex(pUtf16);
    vUnit pls_integer;
  begin
    for i in 0..length(vHex) / 4 - 1
    loop
      vUnit := to_number(substr(vHex, i * 4 + 1, 4), 'XXXX');
      if pPendingHigh <> 0 and vUnit between LOW_SURROGATE_FIRST and LOW_SURROGATE_LAST then
        AddCodePoint(
          pScan
        , SUPPLEMENTARY_FIRST + (pPendingHigh - HIGH_SURROGATE_FIRST) * 1024 + (vUnit - LOW_SURROGATE_FIRST)
        );
        pPendingHigh := 0;
      else
        if pPendingHigh <> 0 then
          AddCodePoint(pScan, pPendingHigh);
          pPendingHigh := 0;
        end if;
        if vUnit between HIGH_SURROGATE_FIRST and HIGH_SURROGATE_LAST then
          pPendingHigh := vUnit;
        else
          AddCodePoint(pScan, vUnit);
        end if;
      end if;
    end loop;
  end;

  procedure ResetScan(pScan in out nocopy TScan) is
  begin
    pScan.CodePoints.Delete;
    pScan.CpCount := 0;
    pScan.Starts.Delete;
    pScan.Graphemes := 0;
  end;

  -- pText is VARCHAR2 or NVARCHAR2; both are converted to UTF-16 in the same way
  procedure DecodeChars(pText varchar2 character set any_cs, pScan in out nocopy TScan) is
    vLength      pls_integer := nvl(length(pText), 0);
    vPos         pls_integer := 1;
    vPendingHigh pls_integer := 0;
  begin
    ResetScan(pScan);
    while vPos <= vLength
    loop
      AddUtf16(pScan, utl_i18n.string_to_raw(substr(pText, vPos, CHUNK_SIZE), 'AL16UTF16'), vPendingHigh);
      vPos := vPos + CHUNK_SIZE;
    end loop;
    if vPendingHigh <> 0 then
      AddCodePoint(pScan, vPendingHigh);
    end if;
  end;

  procedure DecodeLob(pText clob, pScan in out nocopy TScan) is
    vLength      pls_integer := nvl(dbms_lob.getlength(pText), 0);
    vPos         pls_integer := 1;
    vAmount      pls_integer;
    vChunk       varchar2(32767);
    vPendingHigh pls_integer := 0;
  begin
    ResetScan(pScan);
    while vPos <= vLength
    loop
      vAmount := least(CHUNK_SIZE, vLength - vPos + 1);
      loop
        begin
          vChunk := dbms_lob.substr(pText, vAmount, vPos);
          exit;
        exception
          when LOB_AMOUNT_NOT_ON_BOUNDARY or LOB_AMOUNT_ZERO_ON_WRITE then
            -- the chunk ends between the halves of a pair; take one unit fewer
            if vAmount <= 1 then
              raise;
            end if;
            vAmount := vAmount - 1;
        end;
      end loop;
      AddUtf16(pScan, utl_i18n.string_to_raw(vChunk, 'AL16UTF16'), vPendingHigh);
      -- A chunk ending inside a pair may come back without that half character, so advance by what was returned
      vPos := vPos + greatest(length2(vChunk), 1);
    end loop;
    if vPendingHigh <> 0 then
      AddCodePoint(pScan, vPendingHigh);
    end if;
  end;

  ---------------------------------------------------------------------------
  -- UAX #29 boundary scan
  ---------------------------------------------------------------------------

  -- Fills pScan.Starts / pScan.Graphemes from pScan.CodePoints
  procedure Scan(pScan in out nocopy TScan) is
    vProp        pls_integer;
    vGcb         pls_integer;
    vPrevGcb     pls_integer := 0;
    vIncb        pls_integer;
    vIsPict      boolean;
    vIsBreak     boolean;
    vEmojiState  pls_integer := 0;  -- 1: ExtPict Extend*   2: ExtPict Extend* ZWJ
    vAfterLinker boolean := False;  -- GB9c: Linker Extend* so far
    vRiRun       pls_integer := 0;  -- number of consecutive regional indicators before this code point
  begin
    pScan.Starts.Delete;
    pScan.Graphemes := 0;
    for i in 1..pScan.CpCount
    loop
      vProp   := PropertyOf(pScan.CodePoints(i));
      vGcb    := bitand(vProp, 15);
      vIsPict := bitand(vProp, 16) <> 0;
      vIncb   := bitand(trunc(vProp / 32), 3);

      vIsBreak := case
                    when i = 1 then True                                                         -- GB1
                    when vPrevGcb = GCB_CR and vGcb = GCB_LF then False                          -- GB3
                    when vPrevGcb in (GCB_CONTROL, GCB_CR, GCB_LF) then True                     -- GB4
                    when vGcb in (GCB_CONTROL, GCB_CR, GCB_LF) then True                         -- GB5
                    when vPrevGcb = GCB_L and vGcb in (GCB_L, GCB_V, GCB_LV, GCB_LVT) then False -- GB6
                    when vPrevGcb in (GCB_LV, GCB_V) and vGcb in (GCB_V, GCB_T) then False       -- GB7
                    when vPrevGcb in (GCB_LVT, GCB_T) and vGcb = GCB_T then False                -- GB8
                    when vGcb in (GCB_EXTEND, GCB_ZWJ) then False                                -- GB9
                    when vGcb = GCB_SPACING_MARK then False                                      -- GB9a
                    when vPrevGcb = GCB_PREPEND then False                                       -- GB9b
                    when vIncb = INCB_CONSONANT and vAfterLinker then False                      -- GB9c
                    when vIsPict and vEmojiState = 2 then False                                  -- GB11
                    when vPrevGcb = GCB_RI and vGcb = GCB_RI and mod(vRiRun, 2) = 1 then False   -- GB12, GB13
                    else True                                                                    -- GB999
                  end;

      if vIsBreak then
        pScan.Graphemes := pScan.Graphemes + 1;
        pScan.Starts(pScan.Graphemes) := i;
      end if;

      -- state carried to the next code point
      if vIsPict then
        vEmojiState := 1;
      elsif vGcb = GCB_EXTEND and vEmojiState = 1 then
        null;
      elsif vGcb = GCB_ZWJ and vEmojiState = 1 then
        vEmojiState := 2;
      else
        vEmojiState := 0;
      end if;

      if vIncb = INCB_LINKER then
        vAfterLinker := True;
      elsif vIncb <> INCB_EXTEND then
        vAfterLinker := False;                                                    -- InCB=Extend keeps the state
      end if;

      if vGcb = GCB_RI then
        vRiRun := vRiRun + 1;
      else
        vRiRun := 0;
      end if;

      vPrevGcb := vGcb;
    end loop;
    pScan.Starts(pScan.Graphemes + 1) := pScan.CpCount + 1;
  end;

  -- KIND_CHAR or KIND_NCHAR: a probe character is 1 byte in the database character set (AL32UTF8), 2 in AL16UTF16
  function KindOf(pText varchar2 character set any_cs) return pls_integer is
    vProbe  varchar2(10) character set pText%charset := 'a';
    vResult pls_integer := KIND_CHAR;
  begin
    if lengthb(vProbe) > 1 then
      vResult := KIND_NCHAR;
    end if;
    return vResult;
  end;

  procedure AnalyseChars(pText varchar2 character set any_cs, pScan in out nocopy TScan) is
  begin
    DecodeChars(pText, pScan);
    Scan(pScan);
  end;

  procedure AnalyseLob(pText clob, pScan in out nocopy TScan) is
  begin
    DecodeLob(pText, pScan);
    Scan(pScan);
  end;

  ---------------------------------------------------------------------------
  -- Offsets
  ---------------------------------------------------------------------------

  -- Resolves UNIT_NATIVE and validates pUnit for the datatype
  function ResolveUnit(pUnit pls_integer, pKind pls_integer) return pls_integer is
    vUnit pls_integer := nvl(pUnit, UNIT_NATIVE);
  begin
    if vUnit = UNIT_NATIVE then
      if pKind = KIND_CHAR then
        vUnit := UNIT_CODEPOINT;
      else
        vUnit := UNIT_UTF16;
      end if;
    elsif vUnit = UNIT_BYTE and pKind = KIND_LOB then
      raise_application_error(C_INVALID_UNIT, 'UNIT_BYTE is not supported for CLOB');
    elsif vUnit not in (UNIT_CODEPOINT, UNIT_UTF16, UNIT_BYTE) then
      raise_application_error(C_INVALID_UNIT, 'Invalid unit: ' || vUnit);
    end if;
    return vUnit;
  end;

  -- Width of a code point in a unit (pUnit is resolved)
  function WidthOf(pCodePoint pls_integer, pUnit pls_integer, pKind pls_integer) return pls_integer is
  begin
    return case
             when pUnit = UNIT_UTF16 then
               case when pCodePoint >= SUPPLEMENTARY_FIRST then 2 else 1 end
             -- UNIT_BYTE in UTF-16: 2 bytes, or 4 for a surrogate pair
             when pUnit = UNIT_BYTE and pKind = KIND_NCHAR then
               case when pCodePoint >= SUPPLEMENTARY_FIRST then 4 else 2 end
             -- UNIT_BYTE in UTF-8
             when pUnit = UNIT_BYTE and pCodePoint >= SUPPLEMENTARY_FIRST then 4
             when pUnit = UNIT_BYTE and pCodePoint >= 2048 then 3
             when pUnit = UNIT_BYTE and pCodePoint >= 128 then 2
             else 1
           end;
  end;

  -- pOffsets(1..Graphemes + 1): where each cluster starts (and the end of the text) in a resolved unit
  procedure ToOffsets(
              pScan    in            TScan
            , pUnit    in            pls_integer
            , pKind    in            pls_integer
            , pOffsets in out nocopy TIntList
            ) is
    vOffset  pls_integer := 1;
    vCluster pls_integer := 1;
  begin
    pOffsets.Delete;
    if pUnit = UNIT_CODEPOINT then
      for i in 1..pScan.Graphemes + 1
      loop
        pOffsets(i) := pScan.Starts(i);
      end loop;
    else
      for i in 1..pScan.CpCount + 1
      loop
        if pScan.Starts(vCluster) = i then
          pOffsets(vCluster) := vOffset;
          vCluster := vCluster + 1;
        end if;
        if i <= pScan.CpCount then
          vOffset := vOffset + WidthOf(pScan.CodePoints(i), pUnit, pKind);
        end if;
      end loop;
    end if;
  end;

  function BoundariesOf(pScan TScan, pUnit pls_integer, pKind pls_integer) return CL_GraphemeOffsets is
    vOffsets TIntList;
    vResult  CL_GraphemeOffsets := CL_GraphemeOffsets();
  begin
    ToOffsets(pScan, ResolveUnit(pUnit, pKind), pKind, vOffsets);
    vResult.Extend(pScan.Graphemes + 1);
    for i in 1..pScan.Graphemes + 1
    loop
      vResult(i) := vOffsets(i);
    end loop;
    return vResult;
  end;

  function IsBoundaryOf(pScan TScan, pOffset integer, pUnit pls_integer, pKind pls_integer) return boolean is
    vOffsets TIntList;
    vResult  boolean := False;
  begin
    ToOffsets(pScan, ResolveUnit(pUnit, pKind), pKind, vOffsets);
    if pOffset is not null then
      for i in 1..pScan.Graphemes + 1
      loop
        if vOffsets(i) >= pOffset then
          vResult := vOffsets(i) = pOffset;
          exit;
        end if;
      end loop;
    end if;
    return vResult;
  end;

  function OffsetOf(pScan TScan, pIndex integer, pUnit pls_integer, pKind pls_integer) return integer is
    vOffsets TIntList;
  begin
    if pIndex is null or pIndex < 1 or pIndex > pScan.Graphemes then
      raise_application_error(
        C_INDEX_OUT_OF_RANGE
      , 'Grapheme index ' || nvl(to_char(pIndex), 'null') || ' is out of range 1..' || pScan.Graphemes
      );
    end if;
    ToOffsets(pScan, ResolveUnit(pUnit, pKind), pKind, vOffsets);
    return vOffsets(pIndex);
  end;

  ---------------------------------------------------------------------------
  -- Extracting clusters
  ---------------------------------------------------------------------------

  /*
    Grapheme index range pFrom..pTo selected by (pStart, pCount); both null when nothing is selected.
    pStrict (GraphemeAt): pStart must be an existing cluster.
    Otherwise (GraphemeSubstr): like SUBSTR, pCount null = to the end, past-the-end selects nothing.
  */
  procedure ClusterRange(
              pScan   in     TScan
            , pStart  in     integer
            , pCount  in     integer
            , pStrict in     boolean
            , pFrom      out pls_integer
            , pTo        out pls_integer
            ) is
  begin
    pFrom := null;
    pTo := null;
    if pStrict then
      if pStart is null or pStart < 1 or pStart > pScan.Graphemes then
        raise_application_error(
          C_INDEX_OUT_OF_RANGE
        , 'Grapheme index ' || nvl(to_char(pStart), 'null') || ' is out of range 1..' || pScan.Graphemes
        );
      end if;
      pFrom := pStart;
      pTo := pStart;
    elsif pStart is not null then
      if pStart < 1 then
        raise_application_error(C_INDEX_OUT_OF_RANGE, 'Grapheme start ' || pStart || ' must be at least 1');
      elsif pCount < 0 then
        raise_application_error(C_INDEX_OUT_OF_RANGE, 'Grapheme length ' || pCount || ' must not be negative');
      elsif pStart <= pScan.Graphemes and (pCount is null or pCount > 0) then
        pFrom := pStart;
        pTo := pScan.Graphemes;
        if pCount is not null then
          pTo := least(pTo, pStart + pCount - 1);
        end if;
      end if;
    end if;
  end;

  -- VARCHAR2 / NVARCHAR2: the result has the character set of pText
  function SliceChars(
             pText   varchar2 character set any_cs
           , pStart  integer
           , pCount  integer
           , pStrict boolean
           ) return varchar2 character set pText%charset is
    vScan    TScan;
    vFrom    pls_integer;
    vTo      pls_integer;
    vOffsets TIntList;
    vKind    pls_integer := KindOf(pText);
    vResult  varchar2(32767) character set pText%charset;
  begin
    AnalyseChars(pText, vScan);
    ClusterRange(vScan, pStart, pCount, pStrict, vFrom, vTo);
    if vFrom is not null then
      ToOffsets(vScan, ResolveUnit(UNIT_NATIVE, vKind), vKind, vOffsets);
      vResult := substr(pText, vOffsets(vFrom), vOffsets(vTo + 1) - vOffsets(vFrom));
    end if;
    return vResult;
  end;

  function SliceLob(pText clob, pStart integer, pCount integer, pStrict boolean) return clob is
    vScan    TScan;
    vFrom    pls_integer;
    vTo      pls_integer;
    vOffsets TIntList;
    vResult  clob;
  begin
    AnalyseLob(pText, vScan);
    ClusterRange(vScan, pStart, pCount, pStrict, vFrom, vTo);
    if vFrom is not null then
      ToOffsets(vScan, UNIT_UTF16, KIND_LOB, vOffsets);
      dbms_lob.createtemporary(vResult, True);
      dbms_lob.copy(vResult, pText, vOffsets(vTo + 1) - vOffsets(vFrom), 1, vOffsets(vFrom));
    end if;
    return vResult;
  end;

  ---------------------------------------------------------------------------
  -- Cluster list (iterator rows)
  ---------------------------------------------------------------------------

  -- vNative: offsets in the datatype's native unit, used to cut the cluster text out of pText
  function ListChars(pText varchar2 character set any_cs, pUnit pls_integer) return CL_GraphemeList is
    vScan     TScan;
    vNative   TIntList;
    vOffsets  TIntList;
    vKind     pls_integer := KindOf(pText);
    vUnit     pls_integer := ResolveUnit(pUnit, vKind);
    vNativeLn pls_integer;
    vResult   CL_GraphemeList := CL_GraphemeList();
  begin
    AnalyseChars(pText, vScan);
    ToOffsets(vScan, ResolveUnit(UNIT_NATIVE, vKind), vKind, vNative);
    ToOffsets(vScan, vUnit, vKind, vOffsets);
    vResult.Extend(vScan.Graphemes);
    for i in 1..vScan.Graphemes
    loop
      vNativeLn := vNative(i + 1) - vNative(i);
      if vNativeLn > MAX_CLUSTER_LENGTH then
        raise_application_error(C_CLUSTER_TOO_LONG, 'Grapheme cluster ' || i || ' is longer than ' || MAX_CLUSTER_LENGTH);
      end if;
      vResult(i) := TY_Grapheme(
                      i
                    , vOffsets(i)
                    , vOffsets(i + 1) - vOffsets(i)
                    , to_nchar(substr(pText, vNative(i), vNativeLn))
                    );
    end loop;
    return vResult;
  end;

  function ListLob(pText clob, pUnit pls_integer) return CL_GraphemeList is
    vScan     TScan;
    vNative   TIntList;
    vOffsets  TIntList;
    vUnit     pls_integer := ResolveUnit(pUnit, KIND_LOB);
    vNativeLn pls_integer;
    vResult   CL_GraphemeList := CL_GraphemeList();
  begin
    AnalyseLob(pText, vScan);
    ToOffsets(vScan, UNIT_UTF16, KIND_LOB, vNative);
    ToOffsets(vScan, vUnit, KIND_LOB, vOffsets);
    vResult.Extend(vScan.Graphemes);
    for i in 1..vScan.Graphemes
    loop
      vNativeLn := vNative(i + 1) - vNative(i);
      if vNativeLn > MAX_CLUSTER_LENGTH then
        raise_application_error(C_CLUSTER_TOO_LONG, 'Grapheme cluster ' || i || ' is longer than ' || MAX_CLUSTER_LENGTH);
      end if;
      vResult(i) := TY_Grapheme(
                      i
                    , vOffsets(i)
                    , vOffsets(i + 1) - vOffsets(i)
                    , to_nchar(dbms_lob.substr(pText, vNativeLn, vNative(i)))
                    );
    end loop;
    return vResult;
  end;

  ---------------------------------------------------------------------------
  -- Code point list
  ---------------------------------------------------------------------------

  -- A code point as a national character string; supplementary characters become a surrogate pair
  function CodePointText(pCodePoint pls_integer) return nvarchar2 is
    vOffset pls_integer;
    vResult nvarchar2(2);
  begin
    if pCodePoint < SUPPLEMENTARY_FIRST then
      vResult := unistr('\' || lpad(to_char(pCodePoint, 'FMXXXX'), 4, '0'));
    else
      vOffset := pCodePoint - SUPPLEMENTARY_FIRST;
      vResult := unistr(
                   '\' || to_char(HIGH_SURROGATE_FIRST + trunc(vOffset / 1024), 'FMXXXX')
                 || '\' || to_char(LOW_SURROGATE_FIRST + mod(vOffset, 1024), 'FMXXXX')
                 );
    end if;
    return vResult;
  end;

  function ListCodePoints(pScan TScan) return CL_CodePointList is
    vResult CL_CodePointList := CL_CodePointList();
  begin
    vResult.Extend(pScan.CpCount);
    for g in 1..pScan.Graphemes
    loop
      for i in pScan.Starts(g)..pScan.Starts(g + 1) - 1
      loop
        vResult(i) := TY_CodePoint(
                        i
                      , g
                      , pScan.CodePoints(i)
                      , 'U+' || lpad(to_char(pScan.CodePoints(i), 'FMXXXXXX'), 4, '0')
                      , CodePointText(pScan.CodePoints(i))
                      );
      end loop;
    end loop;
    return vResult;
  end;

  ---------------------------------------------------------------------------
  -- Public routines
  ---------------------------------------------------------------------------

  function GraphemeCount(pText varchar2 character set any_cs) return integer is
    vScan TScan;
  begin
    AnalyseChars(pText, vScan);
    return vScan.Graphemes;
  end;

  function GraphemeCount(pText clob) return integer is
    vScan TScan;
  begin
    AnalyseLob(pText, vScan);
    return vScan.Graphemes;
  end;

  function GraphemeAt(
             pText  varchar2 character set any_cs
           , pIndex integer
           ) return varchar2 character set pText%charset is
  begin
    return SliceChars(pText, pIndex, 1, True);
  end;

  function GraphemeAt(pText clob, pIndex integer) return clob is
  begin
    return SliceLob(pText, pIndex, 1, True);
  end;

  function GraphemeSubstr(
             pText   varchar2 character set any_cs
           , pStart  integer
           , pLength integer default null
           ) return varchar2 character set pText%charset is
  begin
    return SliceChars(pText, pStart, pLength, False);
  end;

  function GraphemeSubstr(pText clob, pStart integer, pLength integer default null) return clob is
  begin
    return SliceLob(pText, pStart, pLength, False);
  end;

  function GraphemeTruncate(
             pText      varchar2 character set any_cs
           , pMaxLength integer
           ) return varchar2 character set pText%charset is
  begin
    return SliceChars(pText, 1, pMaxLength, False);
  end;

  function GraphemeTruncate(pText clob, pMaxLength integer) return clob is
  begin
    return SliceLob(pText, 1, pMaxLength, False);
  end;

  function GraphemeBoundaries(
             pText varchar2 character set any_cs
           , pUnit pls_integer default UNIT_NATIVE
           ) return CL_GraphemeOffsets is
    vScan TScan;
  begin
    AnalyseChars(pText, vScan);
    return BoundariesOf(vScan, pUnit, KindOf(pText));
  end;

  function GraphemeBoundaries(pText clob, pUnit pls_integer default UNIT_NATIVE) return CL_GraphemeOffsets is
    vScan TScan;
  begin
    AnalyseLob(pText, vScan);
    return BoundariesOf(vScan, pUnit, KIND_LOB);
  end;

  function IsGraphemeBoundary(
             pText   varchar2 character set any_cs
           , pOffset integer
           , pUnit   pls_integer default UNIT_NATIVE
           ) return boolean is
    vScan TScan;
  begin
    AnalyseChars(pText, vScan);
    return IsBoundaryOf(vScan, pOffset, pUnit, KindOf(pText));
  end;

  function IsGraphemeBoundary(pText clob, pOffset integer, pUnit pls_integer default UNIT_NATIVE) return boolean is
    vScan TScan;
  begin
    AnalyseLob(pText, vScan);
    return IsBoundaryOf(vScan, pOffset, pUnit, KIND_LOB);
  end;

  function GraphemeOffset(
             pText  varchar2 character set any_cs
           , pIndex integer
           , pUnit  pls_integer default UNIT_NATIVE
           ) return integer is
    vScan TScan;
  begin
    AnalyseChars(pText, vScan);
    return OffsetOf(vScan, pIndex, pUnit, KindOf(pText));
  end;

  function GraphemeOffset(pText clob, pIndex integer, pUnit pls_integer default UNIT_NATIVE) return integer is
    vScan TScan;
  begin
    AnalyseLob(pText, vScan);
    return OffsetOf(vScan, pIndex, pUnit, KIND_LOB);
  end;

  function GraphemeList(
             pText varchar2 character set any_cs
           , pUnit pls_integer default UNIT_NATIVE
           ) return CL_GraphemeList is
  begin
    return ListChars(pText, pUnit);
  end;

  function GraphemeList(pText clob, pUnit pls_integer default UNIT_NATIVE) return CL_GraphemeList is
  begin
    return ListLob(pText, pUnit);
  end;

  function GraphemeIterator(
             pText varchar2 character set any_cs
           , pUnit pls_integer default UNIT_NATIVE
           ) return CL_GraphemeList pipelined is
    vList CL_GraphemeList := ListChars(pText, pUnit);
  begin
    for i in 1..vList.Count
    loop
      pipe row (vList(i));
    end loop;
    return;
  end;

  function GraphemeIterator(pText clob, pUnit pls_integer default UNIT_NATIVE) return CL_GraphemeList pipelined is
    vList CL_GraphemeList := ListLob(pText, pUnit);
  begin
    for i in 1..vList.Count
    loop
      pipe row (vList(i));
    end loop;
    return;
  end;

  function CodePoints(pText varchar2 character set any_cs) return CL_CodePointList pipelined is
    vScan TScan;
    vList CL_CodePointList;
  begin
    AnalyseChars(pText, vScan);
    vList := ListCodePoints(vScan);
    for i in 1..vList.Count
    loop
      pipe row (vList(i));
    end loop;
    return;
  end;

  function CodePoints(pText clob) return CL_CodePointList pipelined is
    vScan TScan;
    vList CL_CodePointList;
  begin
    AnalyseLob(pText, vScan);
    vList := ListCodePoints(vScan);
    for i in 1..vList.Count
    loop
      pipe row (vList(i));
    end loop;
    return;
  end;

begin
  -- BEGIN GENERATED UNICODE DATA
  AddRuns('0=03,A=02,B=03,D=01,E=03,20=00,7F=03,A0=00,A9=10,AA=00,AD=03,AE=10,AF=00,300=64,370=00,483=64,48A=00,591=64,5BE=00,5BF=64,5C0=00,5C1=64,5C3=00,5C4=64,5C6=00,5C7=64,5CA=00,600=07,606=00,610=64,61B=00,61C=03,61D=00,64B=64,660=00,670=64,671=00,6D6=64,6DD=07,6DE=00,6DF=64,6E5=00,6E7=64,6E9=00,6EA=64,6EE=00,70F=07,710=00,711=64,712=00,730=64,74B=00,7A6=64,7B1=00,7EB=64,7F4=00,7FD=64,7FE=00,816=64,81A=00,81B=64,824=00,825=64,828=00,829=64,82E=00,859=64,85C=00,890=07,892=00,897=64,8A0=00,8CA=64,8E2=07,8E3=64,903=08,904=00,915=20,93A=64,93B=08,93C=64,93D=00,93E=08,941=64,949=08,94D=44,94E=08,950=00,951=64,958=20,960=00,962=64,964=00,978=20,980=00,981=64,982=08,984=00,995=20,9A9=00,9AA=20,9B1=00,9B2=20,9B3=00,9B6=20,9BA=00,9BC=64,9BD=00,9BE=64,9BF=08,9C1=64,9C5=00,9C7=08,9C9=00,9CB=08,9CD=44,9CE=00,9D7=64,9D8=00,9DC=20,9DE=00,9DF=20,9E0=00,9E2=64,9E4=00,9F0=20,9F2=00,9FE=64,9FF=00,A01=64,A03=08,A04=00,A3C=64,A3D=00,A3E=08,A41=64,A43=00,A47=64,A49=00,A4B=64,A4E=00,A51=64,A52=00,A70=64,A72=00,A75=64,A76=00,A81=64,A83=08,A84=00,A95=20,AA9=00,AAA=20,AB1=00,AB2=20,AB4=00,AB5=20,ABA=00,ABC=64,ABD=00,ABE=08,AC1=64,AC6=00,AC7=64,AC9=08,ACA=00,ACB=08,ACD=44,ACE=00,AE2=64,AE4=00,AF9=20,AFA=64,B00=00,B01=64,B02=08,B04=00,B15=20,B29=00,B2A=20,B31=00,B32=20,B34=00,B35=20,B3A=00,B3C=64,B3D=00,B3E=64,B40=08,B41=64,B45=00,B47=08,B49=00,B4B=08,B4D=44,B4E=00,B53=64,B58=00,B5C=20,B5E=00,B5F=20,B60=00,B62=64,B64=00,B71=20,B72=00,B82=64,B83=00,BBE=64,BBF=08,BC0=64,BC1=08,BC3=00,BC6=08,BC9=00,BCA=08,BCD=64,BCE=00,BD7=64,BD8=00,C00=64,C01=08,C04=64,C05=00,C15=20,C29=00,C2A=20,C3A=00,C3C=64,C3D=00,C3E=64,C41=08,C45=00,C46=64,C49=00,C4A=64,C4D=44,C4E=00,C55=64,C57=00,C58=20,C5B=00,C62=64,C64=00,C81=64,C82=08,C84=00,CBC=64,CBD=00,CBE=08,CBF=64,CC1=08,CC2=64,CC3=08,CC5=00,CC6=64,CC9=00,CCA=64,CCE=00');
  AddRuns('CD5=64,CD7=00,CE2=64,CE4=00,CF3=08,CF4=00,D00=64,D02=08,D04=00,D15=20,D3B=64,D3D=00,D3E=64,D3F=08,D41=64,D45=00,D46=08,D49=00,D4A=08,D4D=44,D4E=07,D4F=00,D57=64,D58=00,D62=64,D64=00,D81=64,D82=08,D84=00,DCA=64,DCB=00,DCF=64,DD0=08,DD2=64,DD5=00,DD6=64,DD7=00,DD8=08,DDF=64,DE0=00,DF2=08,DF4=00,E31=64,E32=00,E33=08,E34=64,E3B=00,E47=64,E4F=00,EB1=64,EB2=00,EB3=08,EB4=64,EBD=00,EC8=64,ECF=00,F18=64,F1A=00,F35=64,F36=00,F37=64,F38=00,F39=64,F3A=00,F3E=08,F40=00,F71=64,F7F=08,F80=64,F85=00,F86=64,F88=00,F8D=64,F98=00,F99=64,FBD=00,FC6=64,FC7=00,1000=20,102B=00,102D=64,1031=08,1032=64,1038=00,1039=44,103A=64,103B=08,103D=64,103F=20,1040=00,1050=20,1056=08,1058=64,105A=20,105E=64,1061=20,1062=00,1065=20,1067=00,106E=20,1071=64,1075=20,1082=64,1083=00,1084=08,1085=64,1087=00,108D=64,108E=20,108F=00,109D=64,109E=00,1100=09,1160=0A,11A8=0B,1200=00,135D=64,1360=00,1712=64,1716=00,1732=64,1735=00,1752=64,1754=00,1772=64,1774=00,1780=20,17B4=64,17B6=08,17B7=64,17BE=08,17C6=64,17C7=08,17C9=64,17D2=44,17D3=64,17D4=00,17DD=64,17DE=00,180B=64,180E=03,180F=64,1810=00,1885=64,1887=00,18A9=64,18AA=00,1920=64,1923=08,1927=64,1929=08,192C=00,1930=08,1932=64,1933=08,1939=64,193C=00,1A17=64,1A19=08,1A1B=64,1A1C=00,1A20=20,1A55=08,1A56=64,1A57=08,1A58=64,1A5F=00,1A60=44,1A61=00,1A62=64,1A63=00,1A65=64,1A6D=08,1A73=64,1A7D=00,1A7F=64,1A80=00,1AB0=64,1AF1=00,1B00=64,1B04=08,1B05=00,1B0B=20,1B0D=00,1B13=20,1B34=64,1B3E=08,1B42=64,1B44=44,1B45=20,1B4D=00,1B6B=64,1B74=00,1B80=64,1B82=08,1B83=20,1BA1=08,1BA2=64,1BA6=08,1BA8=64,1BAB=44,1BAC=64,1BAE=20,1BB0=00,1BBB=20,1BBE=00,1BE6=64,1BE7=08,1BE8=64,1BEA=08,1BED=64,1BEE=08,1BEF=64,1BF4=00,1C24=08,1C2C=64,1C34=08,1C36=64,1C38=00,1CD0=64,1CD3=00,1CD4=64,1CE1=08,1CE2=64,1CE9=00,1CED=64,1CEE=00,1CF4=64,1CF5=40,1CF7=08,1CF8=64,1CFA=00,1DC0=64,1E00=00');
  AddRuns('200B=03,200C=04,200D=65,200E=03,2010=00,2028=03,202F=00,203C=10,203D=00,2049=10,204A=00,2060=03,2070=00,20D0=64,20F1=00,2122=10,2123=00,2139=10,213A=00,2194=10,219A=00,21A9=10,21AB=00,231A=10,231C=00,2328=10,2329=00,23CF=10,23D0=00,23E9=10,23F4=00,23F8=10,23FB=00,24C2=10,24C3=00,25AA=10,25AC=00,25B6=10,25B7=00,25C0=10,25C1=00,25FB=10,25FF=00,2600=10,2605=00,260E=10,260F=00,2611=10,2612=00,2614=10,2616=00,2618=10,2619=00,261D=10,261E=00,2620=10,2621=00,2622=10,2624=00,2626=10,2627=00,262A=10,262B=00,262E=10,2630=00,2638=10,263B=00,2640=10,2641=00,2642=10,2643=00,2648=10,2654=00,265F=10,2661=00,2663=10,2664=00,2665=10,2667=00,2668=10,2669=00,267B=10,267C=00,267E=10,2680=00,2692=10,2698=00,2699=10,269A=00,269B=10,269D=00,26A0=10,26A2=00,26A7=10,26A8=00,26AA=10,26AC=00,26B0=10,26B2=00,26BD=10,26BF=00,26C4=10,26C6=00,26C8=10,26C9=00,26CE=10,26D0=00,26D1=10,26D2=00,26D3=10,26D5=00,26E9=10,26EB=00,26F0=10,26F6=00,26F7=10,26FB=00,26FD=10,26FE=00,2702=10,2703=00,2705=10,2706=00,2708=10,270E=00,270F=10,2710=00,2712=10,2713=00,2714=10,2715=00,2716=10,2717=00,271D=10,271E=00,2721=10,2722=00,2728=10,2729=00,2733=10,2735=00,2744=10,2745=00,2747=10,2748=00,274C=10,274D=00,274E=10,274F=00,2753=10,2756=00,2757=10,2758=00,2763=10,2765=00,2795=10,2798=00,27A1=10,27A2=00,27B0=10,27B1=00,27BF=10,27C0=00,2934=10,2936=00,2B05=10,2B08=00,2B1B=10,2B1D=00,2B50=10,2B51=00,2B55=10,2B56=00,2CEF=64,2CF2=00,2D7F=64,2D80=00,2DE0=64,2E00=00,302A=64,3030=10,3031=00,303D=10,303E=00,3099=64,309B=00,3297=10,3298=00,3299=10,329A=00,A66F=64,A673=00,A674=64,A67E=00,A69E=64,A6A0=00,A6F0=64,A6F2=00,A802=64,A803=00,A806=64,A807=00,A80B=64,A80C=00,A823=08,A825=64,A827=08,A828=00,A82C=64,A82D=00,A880=08,A882=00,A8B4=08,A8C4=64,A8C6=00,A8E0=64,A8F2=00,A8FF=64,A900=00,A926=64,A92E=00,A947=64,A952=08,A953=64,A954=00');
  AddRuns('A960=09,A97D=00,A980=64,A983=08,A984=00,A989=20,A98C=00,A98F=20,A9B3=64,A9B4=08,A9B6=64,A9BA=08,A9BC=64,A9BE=08,A9C0=44,A9C1=00,A9E0=20,A9E5=64,A9E6=00,A9E7=20,A9F0=00,A9FA=20,A9FF=00,AA29=64,AA2F=08,AA31=64,AA33=08,AA35=64,AA37=00,AA43=64,AA44=00,AA4C=64,AA4D=08,AA4E=00,AA60=20,AA70=00,AA71=20,AA74=00,AA7A=20,AA7B=00,AA7C=64,AA7D=00,AA7E=20,AA80=00,AAB0=64,AAB1=00,AAB2=64,AAB5=00,AAB7=64,AAB9=00,AABE=64,AAC0=00,AAC1=64,AAC2=00,AAE0=20,AAEB=08,AAEC=64,AAEE=08,AAF0=00,AAF5=08,AAF6=44,AAF7=00,ABC0=20,ABDB=00,ABE3=08,ABE5=64,ABE6=08,ABE8=64,ABE9=08,ABEB=00,ABEC=08,ABED=64,ABEE=00,AC00=0C,AC01=0D,AC1C=0C,AC1D=0D,AC38=0C,AC39=0D,AC54=0C,AC55=0D,AC70=0C,AC71=0D,AC8C=0C,AC8D=0D,ACA8=0C,ACA9=0D,ACC4=0C,ACC5=0D,ACE0=0C,ACE1=0D,ACFC=0C,ACFD=0D,AD18=0C,AD19=0D,AD34=0C,AD35=0D,AD50=0C,AD51=0D,AD6C=0C,AD6D=0D,AD88=0C,AD89=0D,ADA4=0C,ADA5=0D,ADC0=0C,ADC1=0D,ADDC=0C,ADDD=0D,ADF8=0C,ADF9=0D,AE14=0C,AE15=0D,AE30=0C,AE31=0D,AE4C=0C,AE4D=0D,AE68=0C,AE69=0D,AE84=0C,AE85=0D,AEA0=0C,AEA1=0D,AEBC=0C,AEBD=0D,AED8=0C,AED9=0D,AEF4=0C,AEF5=0D,AF10=0C,AF11=0D,AF2C=0C,AF2D=0D,AF48=0C,AF49=0D,AF64=0C,AF65=0D,AF80=0C,AF81=0D,AF9C=0C,AF9D=0D,AFB8=0C,AFB9=0D,AFD4=0C,AFD5=0D,AFF0=0C,AFF1=0D,B00C=0C,B00D=0D,B028=0C,B029=0D,B044=0C,B045=0D,B060=0C,B061=0D,B07C=0C,B07D=0D,B098=0C,B099=0D,B0B4=0C,B0B5=0D,B0D0=0C,B0D1=0D,B0EC=0C,B0ED=0D,B108=0C,B109=0D,B124=0C,B125=0D,B140=0C,B141=0D,B15C=0C,B15D=0D,B178=0C,B179=0D,B194=0C,B195=0D,B1B0=0C,B1B1=0D,B1CC=0C,B1CD=0D,B1E8=0C,B1E9=0D,B204=0C,B205=0D,B220=0C,B221=0D,B23C=0C,B23D=0D,B258=0C,B259=0D,B274=0C,B275=0D,B290=0C,B291=0D,B2AC=0C,B2AD=0D,B2C8=0C,B2C9=0D,B2E4=0C,B2E5=0D,B300=0C,B301=0D,B31C=0C,B31D=0D,B338=0C,B339=0D,B354=0C,B355=0D,B370=0C,B371=0D,B38C=0C,B38D=0D,B3A8=0C,B3A9=0D,B3C4=0C,B3C5=0D,B3E0=0C,B3E1=0D,B3FC=0C,B3FD=0D,B418=0C,B419=0D,B434=0C,B435=0D');
  AddRuns('B450=0C,B451=0D,B46C=0C,B46D=0D,B488=0C,B489=0D,B4A4=0C,B4A5=0D,B4C0=0C,B4C1=0D,B4DC=0C,B4DD=0D,B4F8=0C,B4F9=0D,B514=0C,B515=0D,B530=0C,B531=0D,B54C=0C,B54D=0D,B568=0C,B569=0D,B584=0C,B585=0D,B5A0=0C,B5A1=0D,B5BC=0C,B5BD=0D,B5D8=0C,B5D9=0D,B5F4=0C,B5F5=0D,B610=0C,B611=0D,B62C=0C,B62D=0D,B648=0C,B649=0D,B664=0C,B665=0D,B680=0C,B681=0D,B69C=0C,B69D=0D,B6B8=0C,B6B9=0D,B6D4=0C,B6D5=0D,B6F0=0C,B6F1=0D,B70C=0C,B70D=0D,B728=0C,B729=0D,B744=0C,B745=0D,B760=0C,B761=0D,B77C=0C,B77D=0D,B798=0C,B799=0D,B7B4=0C,B7B5=0D,B7D0=0C,B7D1=0D,B7EC=0C,B7ED=0D,B808=0C,B809=0D,B824=0C,B825=0D,B840=0C,B841=0D,B85C=0C,B85D=0D,B878=0C,B879=0D,B894=0C,B895=0D,B8B0=0C,B8B1=0D,B8CC=0C,B8CD=0D,B8E8=0C,B8E9=0D,B904=0C,B905=0D,B920=0C,B921=0D,B93C=0C,B93D=0D,B958=0C,B959=0D,B974=0C,B975=0D,B990=0C,B991=0D,B9AC=0C,B9AD=0D,B9C8=0C,B9C9=0D,B9E4=0C,B9E5=0D,BA00=0C,BA01=0D,BA1C=0C,BA1D=0D,BA38=0C,BA39=0D,BA54=0C,BA55=0D,BA70=0C,BA71=0D,BA8C=0C,BA8D=0D,BAA8=0C,BAA9=0D,BAC4=0C,BAC5=0D,BAE0=0C,BAE1=0D,BAFC=0C,BAFD=0D,BB18=0C,BB19=0D,BB34=0C,BB35=0D,BB50=0C,BB51=0D,BB6C=0C,BB6D=0D,BB88=0C,BB89=0D,BBA4=0C,BBA5=0D,BBC0=0C,BBC1=0D,BBDC=0C,BBDD=0D,BBF8=0C,BBF9=0D,BC14=0C,BC15=0D,BC30=0C,BC31=0D,BC4C=0C,BC4D=0D,BC68=0C,BC69=0D,BC84=0C,BC85=0D,BCA0=0C,BCA1=0D,BCBC=0C,BCBD=0D,BCD8=0C,BCD9=0D,BCF4=0C,BCF5=0D,BD10=0C,BD11=0D,BD2C=0C,BD2D=0D,BD48=0C,BD49=0D,BD64=0C,BD65=0D,BD80=0C,BD81=0D,BD9C=0C,BD9D=0D,BDB8=0C,BDB9=0D,BDD4=0C,BDD5=0D,BDF0=0C,BDF1=0D,BE0C=0C,BE0D=0D,BE28=0C,BE29=0D,BE44=0C,BE45=0D,BE60=0C,BE61=0D,BE7C=0C,BE7D=0D,BE98=0C,BE99=0D,BEB4=0C,BEB5=0D,BED0=0C,BED1=0D,BEEC=0C,BEED=0D,BF08=0C,BF09=0D,BF24=0C,BF25=0D,BF40=0C,BF41=0D,BF5C=0C,BF5D=0D,BF78=0C,BF79=0D,BF94=0C,BF95=0D,BFB0=0C,BFB1=0D,BFCC=0C,BFCD=0D,BFE8=0C,BFE9=0D,C004=0C,C005=0D,C020=0C,C021=0D,C03C=0C,C03D=0D,C058=0C,C059=0D,C074=0C,C075=0D,C090=0C');
  AddRuns('C091=0D,C0AC=0C,C0AD=0D,C0C8=0C,C0C9=0D,C0E4=0C,C0E5=0D,C100=0C,C101=0D,C11C=0C,C11D=0D,C138=0C,C139=0D,C154=0C,C155=0D,C170=0C,C171=0D,C18C=0C,C18D=0D,C1A8=0C,C1A9=0D,C1C4=0C,C1C5=0D,C1E0=0C,C1E1=0D,C1FC=0C,C1FD=0D,C218=0C,C219=0D,C234=0C,C235=0D,C250=0C,C251=0D,C26C=0C,C26D=0D,C288=0C,C289=0D,C2A4=0C,C2A5=0D,C2C0=0C,C2C1=0D,C2DC=0C,C2DD=0D,C2F8=0C,C2F9=0D,C314=0C,C315=0D,C330=0C,C331=0D,C34C=0C,C34D=0D,C368=0C,C369=0D,C384=0C,C385=0D,C3A0=0C,C3A1=0D,C3BC=0C,C3BD=0D,C3D8=0C,C3D9=0D,C3F4=0C,C3F5=0D,C410=0C,C411=0D,C42C=0C,C42D=0D,C448=0C,C449=0D,C464=0C,C465=0D,C480=0C,C481=0D,C49C=0C,C49D=0D,C4B8=0C,C4B9=0D,C4D4=0C,C4D5=0D,C4F0=0C,C4F1=0D,C50C=0C,C50D=0D,C528=0C,C529=0D,C544=0C,C545=0D,C560=0C,C561=0D,C57C=0C,C57D=0D,C598=0C,C599=0D,C5B4=0C,C5B5=0D,C5D0=0C,C5D1=0D,C5EC=0C,C5ED=0D,C608=0C,C609=0D,C624=0C,C625=0D,C640=0C,C641=0D,C65C=0C,C65D=0D,C678=0C,C679=0D,C694=0C,C695=0D,C6B0=0C,C6B1=0D,C6CC=0C,C6CD=0D,C6E8=0C,C6E9=0D,C704=0C,C705=0D,C720=0C,C721=0D,C73C=0C,C73D=0D,C758=0C,C759=0D,C774=0C,C775=0D,C790=0C,C791=0D,C7AC=0C,C7AD=0D,C7C8=0C,C7C9=0D,C7E4=0C,C7E5=0D,C800=0C,C801=0D,C81C=0C,C81D=0D,C838=0C,C839=0D,C854=0C,C855=0D,C870=0C,C871=0D,C88C=0C,C88D=0D,C8A8=0C,C8A9=0D,C8C4=0C,C8C5=0D,C8E0=0C,C8E1=0D,C8FC=0C,C8FD=0D,C918=0C,C919=0D,C934=0C,C935=0D,C950=0C,C951=0D,C96C=0C,C96D=0D,C988=0C,C989=0D,C9A4=0C,C9A5=0D,C9C0=0C,C9C1=0D,C9DC=0C,C9DD=0D,C9F8=0C,C9F9=0D,CA14=0C,CA15=0D,CA30=0C,CA31=0D,CA4C=0C,CA4D=0D,CA68=0C,CA69=0D,CA84=0C,CA85=0D,CAA0=0C,CAA1=0D,CABC=0C,CABD=0D,CAD8=0C,CAD9=0D,CAF4=0C,CAF5=0D,CB10=0C,CB11=0D,CB2C=0C,CB2D=0D,CB48=0C,CB49=0D,CB64=0C,CB65=0D,CB80=0C,CB81=0D,CB9C=0C,CB9D=0D,CBB8=0C,CBB9=0D,CBD4=0C,CBD5=0D,CBF0=0C,CBF1=0D,CC0C=0C,CC0D=0D,CC28=0C,CC29=0D,CC44=0C,CC45=0D,CC60=0C,CC61=0D,CC7C=0C,CC7D=0D,CC98=0C,CC99=0D,CCB4=0C,CCB5=0D,CCD0=0C,CCD1=0D');
  AddRuns('CCEC=0C,CCED=0D,CD08=0C,CD09=0D,CD24=0C,CD25=0D,CD40=0C,CD41=0D,CD5C=0C,CD5D=0D,CD78=0C,CD79=0D,CD94=0C,CD95=0D,CDB0=0C,CDB1=0D,CDCC=0C,CDCD=0D,CDE8=0C,CDE9=0D,CE04=0C,CE05=0D,CE20=0C,CE21=0D,CE3C=0C,CE3D=0D,CE58=0C,CE59=0D,CE74=0C,CE75=0D,CE90=0C,CE91=0D,CEAC=0C,CEAD=0D,CEC8=0C,CEC9=0D,CEE4=0C,CEE5=0D,CF00=0C,CF01=0D,CF1C=0C,CF1D=0D,CF38=0C,CF39=0D,CF54=0C,CF55=0D,CF70=0C,CF71=0D,CF8C=0C,CF8D=0D,CFA8=0C,CFA9=0D,CFC4=0C,CFC5=0D,CFE0=0C,CFE1=0D,CFFC=0C,CFFD=0D,D018=0C,D019=0D,D034=0C,D035=0D,D050=0C,D051=0D,D06C=0C,D06D=0D,D088=0C,D089=0D,D0A4=0C,D0A5=0D,D0C0=0C,D0C1=0D,D0DC=0C,D0DD=0D,D0F8=0C,D0F9=0D,D114=0C,D115=0D,D130=0C,D131=0D,D14C=0C,D14D=0D,D168=0C,D169=0D,D184=0C,D185=0D,D1A0=0C,D1A1=0D,D1BC=0C,D1BD=0D,D1D8=0C,D1D9=0D,D1F4=0C,D1F5=0D,D210=0C,D211=0D,D22C=0C,D22D=0D,D248=0C,D249=0D,D264=0C,D265=0D,D280=0C,D281=0D,D29C=0C,D29D=0D,D2B8=0C,D2B9=0D,D2D4=0C,D2D5=0D,D2F0=0C,D2F1=0D,D30C=0C,D30D=0D,D328=0C,D329=0D,D344=0C,D345=0D,D360=0C,D361=0D,D37C=0C,D37D=0D,D398=0C,D399=0D,D3B4=0C,D3B5=0D,D3D0=0C,D3D1=0D,D3EC=0C,D3ED=0D,D408=0C,D409=0D,D424=0C,D425=0D,D440=0C,D441=0D,D45C=0C,D45D=0D,D478=0C,D479=0D,D494=0C,D495=0D,D4B0=0C,D4B1=0D,D4CC=0C,D4CD=0D,D4E8=0C,D4E9=0D,D504=0C,D505=0D,D520=0C,D521=0D,D53C=0C,D53D=0D,D558=0C,D559=0D,D574=0C,D575=0D,D590=0C,D591=0D,D5AC=0C,D5AD=0D,D5C8=0C,D5C9=0D,D5E4=0C,D5E5=0D,D600=0C,D601=0D,D61C=0C,D61D=0D,D638=0C,D639=0D,D654=0C,D655=0D,D670=0C,D671=0D,D68C=0C,D68D=0D,D6A8=0C,D6A9=0D,D6C4=0C,D6C5=0D,D6E0=0C,D6E1=0D,D6FC=0C,D6FD=0D,D718=0C,D719=0D,D734=0C,D735=0D,D750=0C,D751=0D,D76C=0C,D76D=0D,D788=0C,D789=0D,D7A4=00,D7B0=0A,D7C7=00,D7CB=0B,D7FC=00,D800=03,E000=00,FB1E=64,FB1F=00,FE00=64,FE10=00,FE20=64,FE30=00,FEFF=03,FF00=00,FF9E=64,FFA0=00,FFF0=03,FFFC=00,101FD=64,101FE=00,102E0=64,102E1=00,10376=64,1037B=00,10A00=20,10A01=64');
  AddRuns('10A04=00,10A05=64,10A07=00,10A0C=64,10A10=20,10A14=00,10A15=20,10A18=00,10A19=20,10A36=00,10A38=64,10A3B=00,10A3F=44,10A40=00,10AE5=64,10AE7=00,10D24=64,10D28=00,10D69=64,10D6E=00,10EAB=64,10EAD=00,10ECB=64,10ED0=00,10EF0=64,10F00=00,10F46=64,10F51=00,10F82=64,10F86=00,11000=08,11001=64,11002=08,11003=00,11038=64,11047=00,11070=64,11071=00,11073=64,11075=00,1107F=64,11082=08,11083=00,110B0=08,110B3=64,110B7=08,110B9=64,110BB=00,110BD=07,110BE=00,110C2=64,110C3=00,110CD=07,110CE=00,11100=64,11103=20,11127=64,1112C=08,1112D=64,11133=44,11134=64,11135=00,11144=20,11145=08,11147=20,11148=00,11173=64,11174=00,11180=64,11182=08,11183=00,111B3=08,111B6=64,111BF=08,111C0=64,111C1=00,111C2=07,111C4=00,111C9=64,111CD=00,111CE=08,111CF=64,111D0=00,1122C=08,1122F=64,11232=08,11234=64,11238=00,1123E=64,1123F=00,11241=64,11242=00,112DF=64,112E0=08,112E3=64,112EB=00,11300=64,11302=08,11304=00,1133B=64,1133D=00,1133E=64,1133F=08,11340=64,11341=08,11345=00,11347=08,11349=00,1134B=08,1134D=64,1134E=00,11357=64,11358=00,11362=08,11364=00,11366=64,1136D=00,11370=64,11375=00,11380=20,1138A=00,1138B=20,1138C=00,1138E=20,1138F=00,11390=20,113B6=00,113B8=64,113B9=08,113BB=64,113C1=00,113C2=64,113C3=00,113C5=64,113C6=00,113C7=64,113CA=08,113CB=00,113CC=08,113CE=64,113D0=44,113D1=07,113D2=64,113D3=00,113E1=64,113E3=00,11435=08,11438=64,11440=08,11442=64,11445=08,11446=64,11447=00,1145E=64,1145F=00,114B0=64,114B1=08,114B3=64,114B9=08,114BA=64,114BB=08,114BD=64,114BE=08,114BF=64,114C1=08,114C2=64,114C4=00,115AF=64,115B0=08,115B2=64,115B6=00,115B8=08,115BC=64,115BE=08,115BF=64,115C1=00,115DC=64,115DE=00,11630=08,11633=64,1163B=08,1163D=64,1163E=08,1163F=64,11641=00,116AB=64,116AC=08,116AD=64,116AE=08,116B0=64,116B8=00,1171D=64,1171E=08,1171F=64,11720=00,11722=64,11726=08,11727=64,1172C=00,1182C=08');
  AddRuns('1182F=64,11838=08,11839=64,1183B=00,11900=20,11907=00,11909=20,1190A=00,1190C=20,11914=00,11915=20,11917=00,11918=20,11930=64,11931=08,11936=00,11937=08,11939=00,1193B=64,1193E=44,1193F=07,11940=08,11941=07,11942=08,11943=64,11944=00,119D1=08,119D4=64,119D8=00,119DA=64,119DC=08,119E0=64,119E1=00,119E4=08,119E5=00,11A00=20,11A01=64,11A0B=20,11A33=64,11A39=08,11A3A=40,11A3B=64,11A3F=00,11A47=44,11A48=00,11A50=20,11A51=64,11A57=08,11A59=64,11A5C=20,11A84=07,11A8A=64,11A97=08,11A98=64,11A99=44,11A9A=00,11B0A=20,11B0B=00,11B60=64,11B61=08,11B62=64,11B65=08,11B66=64,11B67=08,11B68=00,11C2F=08,11C30=64,11C37=00,11C38=64,11C3E=08,11C3F=64,11C40=00,11C92=64,11CA8=00,11CA9=08,11CAA=64,11CB1=08,11CB2=64,11CB4=08,11CB5=64,11CB7=00,11D31=64,11D37=00,11D3A=64,11D3B=00,11D3C=64,11D3E=00,11D3F=64,11D46=07,11D47=64,11D48=00,11D8A=08,11D8F=00,11D90=64,11D92=00,11D93=08,11D95=64,11D96=08,11D97=64,11D98=00,11DF0=64,11DF1=20,11DF2=00,11EF3=64,11EF5=08,11EF7=00,11F00=64,11F02=07,11F03=08,11F04=20,11F11=00,11F12=20,11F34=08,11F36=64,11F3B=00,11F3E=08,11F40=64,11F42=44,11F43=00,11F5A=64,11F5B=00,13430=03,13440=64,13441=00,13447=64,13456=00,1611E=64,1612A=08,1612D=64,16130=00,16AF0=64,16AF5=00,16B30=64,16B37=00,16D63=0A,16D64=00,16D67=0A,16D6B=00,16F4F=64,16F50=00,16F51=08,16F88=00,16F8F=64,16F93=00,16FE4=64,16FE5=00,16FF0=64,16FF2=00,1BC9D=64,1BC9F=00,1BCA0=03,1BCA4=00,1CF00=64,1CF2E=00,1CF30=64,1CF47=00,1D127=64,1D129=00,1D165=64,1D16A=00,1D16D=64,1D173=03,1D17B=64,1D183=00,1D185=64,1D18C=00,1D1AA=64,1D1AE=00,1D242=64,1D245=00,1D250=64,1D253=00,1D25B=64,1D25D=00,1D25F=64,1D260=00,1D280=64,1D282=00,1DA00=64,1DA37=00,1DA3B=64,1DA6D=00,1DA75=64,1DA76=00,1DA84=64,1DA85=00,1DA9B=64,1DAA0=00,1DAA1=64,1DAB0=00,1E000=64,1E007=00,1E008=64,1E019=00,1E01B=64,1E022=00,1E023=64,1E025=00,1E026=64,1E02B=00');
  AddRuns('1E08F=64,1E090=00,1E130=64,1E137=00,1E2AE=64,1E2AF=00,1E2EC=64,1E2F0=00,1E4EC=64,1E4F0=00,1E5EE=64,1E5F0=00,1E6E3=64,1E6E4=00,1E6E6=64,1E6E7=00,1E6EE=64,1E6F0=00,1E6F5=64,1E6F6=00,1E8D0=64,1E8D7=00,1E944=64,1E94B=00,1F004=10,1F005=00,1F02C=10,1F030=00,1F094=10,1F0A0=00,1F0AF=10,1F0B1=00,1F0C0=10,1F0C1=00,1F0CF=10,1F0D1=00,1F0F6=10,1F100=00,1F170=10,1F172=00,1F17E=10,1F180=00,1F18E=10,1F18F=00,1F191=10,1F19B=00,1F1AF=10,1F1E6=06,1F200=00,1F201=10,1F210=00,1F21A=10,1F21B=00,1F22F=10,1F230=00,1F232=10,1F23B=00,1F23C=10,1F240=00,1F249=10,1F260=00,1F266=10,1F322=00,1F324=10,1F394=00,1F396=10,1F398=00,1F399=10,1F39C=00,1F39E=10,1F3F1=00,1F3F3=10,1F3F6=00,1F3F7=10,1F3FB=64,1F400=10,1F4FE=00,1F4FF=10,1F53E=00,1F549=10,1F54F=00,1F550=10,1F568=00,1F56F=10,1F571=00,1F573=10,1F57B=00,1F587=10,1F588=00,1F58A=10,1F58E=00,1F590=10,1F591=00,1F595=10,1F597=00,1F5A4=10,1F5A6=00,1F5A8=10,1F5A9=00,1F5B1=10,1F5B3=00,1F5BC=10,1F5BD=00,1F5C2=10,1F5C5=00,1F5D1=10,1F5D4=00,1F5DC=10,1F5DF=00,1F5E1=10,1F5E2=00,1F5E3=10,1F5E4=00,1F5E8=10,1F5E9=00,1F5EF=10,1F5F0=00,1F5F3=10,1F5F4=00,1F5FA=10,1F650=00,1F680=10,1F6C6=00,1F6CB=10,1F6D3=00,1F6D5=10,1F6E6=00,1F6E9=10,1F6EA=00,1F6EB=10,1F6F1=00,1F6F3=10,1F700=00,1F7DC=10,1F7F1=00,1F80C=10,1F810=00,1F848=10,1F850=00,1F85A=10,1F860=00,1F888=10,1F890=00,1F8AE=10,1F8B0=00,1F8BC=10,1F8C0=00,1F8C2=10,1F8D0=00,1F8D9=10,1F900=00,1F90C=10,1F93B=00,1F93C=10,1F946=00,1F947=10,1FA00=00,1FA58=10,1FA60=00,1FA6E=10,1FB00=00,1FC00=10,1FFFE=00,E0000=03,E0020=64,E0080=03,E0100=64,E01F0=03,E1000=00');
  -- END GENERATED UNICODE DATA
  BuildLowTable;
end P_Grapheme;
/

