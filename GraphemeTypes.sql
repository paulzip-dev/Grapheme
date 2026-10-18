/*
  Copyright (c) 2026 Paul Scott

  Object types and collections used by P_Grapheme, in dependency order.

  TY_GraphemeIterator's body calls P_Grapheme, which in turn uses the other types here. On a first install
  the body compiles with errors; compile P_Grapheme afterwards and the body revalidates on first use
  (or run: alter type TY_GraphemeIterator compile body;).

  Re-runnable: the types are dropped first, dependents before the types they use, because
  "create or replace type" fails with ORA-02303 once other types depend on it. This fails (ORA-02303)
  if a table column or a type outside this file uses one of them.
*/

declare
  TYPE_DOES_NOT_EXIST exception;
  pragma exception_init(TYPE_DOES_NOT_EXIST, -4043);
begin
  for rec in (
    select column_value as TYPE_NAME
    from table(sys.odcivarchar2list(
           'TY_GraphemeIterator'
         , 'CL_CodePointList'
         , 'TY_CodePoint'
         , 'CL_GraphemeOffsets'
         , 'CL_GraphemeList'
         , 'TY_Grapheme'
         ))
  )
  loop
    begin
      execute immediate 'drop type ' || rec.TYPE_NAME;
    exception
      when TYPE_DOES_NOT_EXIST then
        null;  -- first install
    end;
  end loop;
end;
/

/*
  One extended grapheme cluster, as returned by P_Grapheme.GraphemeIterator.

  IDX        1-based grapheme index
  START_POS  start of the cluster, in the unit requested from the iterator
  LENGTH     length of the cluster in that same unit
  TEXT       the cluster text (clusters longer than 2000 characters are rejected by the iterator)
*/
create or replace
type TY_Grapheme as object (
  IDX       integer
, START_POS integer
, LENGTH    integer
, TEXT      nvarchar2(2000)
);
/

create or replace
type CL_GraphemeList as table of TY_Grapheme;
/

/*
  Offsets returned by P_Grapheme.GraphemeBoundaries.
  Deliberately not sys.ODCINumberList: that is a VARRAY(32767) and would overflow on long texts.
*/
create or replace
type CL_GraphemeOffsets as table of number;
/

/*
  One code point, as returned by P_Grapheme.CodePoints.

  IDX           1-based code point index within the text
  GRAPHEME_IDX  1-based index of the grapheme cluster the code point belongs to
  CODE_POINT    Unicode scalar value (a lone surrogate is returned as its own value)
  HEX           'U+' followed by at least 4 hex digits, e.g. U+1F9D1
  TEXT          the code point as a character (a supplementary character is 2 UTF-16 units)
*/
create or replace
type TY_CodePoint as object (
  IDX          integer
, GRAPHEME_IDX integer
, CODE_POINT   integer
, HEX          varchar2(10)
, TEXT         nvarchar2(2)
);
/

create or replace
type CL_CodePointList as table of TY_CodePoint;
/

/*
  Stateful, procedural iterator over the grapheme clusters of a text.

    declare
      vIterator TY_GraphemeIterator := TY_GraphemeIterator.New(pText);
      vGrapheme TY_Grapheme;
    begin
      while vIterator.HasNext
      loop
        vGrapheme := vIterator.Next;
        ...
      end loop;
    end;

  START_POS / LENGTH of each TY_Grapheme are in pUnit (see P_Grapheme). The text is analysed once, in New.
  For use in SQL see P_Grapheme.GraphemeIterator.
*/
create or replace
type TY_GraphemeIterator as object (
  Graphemes CL_GraphemeList
, Position  integer
  -- Analyses pText once and returns an iterator positioned before the first cluster
, static function New(pText varchar2 character set any_cs, pUnit pls_integer default 0) return TY_GraphemeIterator
, static function New(pText clob, pUnit pls_integer default 0) return TY_GraphemeIterator
  -- True if there is another cluster to return from Next
, member function HasNext return boolean
  -- The next cluster. Raises P_Grapheme.INDEX_OUT_OF_RANGE when there is no next cluster
, member function Next(self in out nocopy TY_GraphemeIterator) return TY_Grapheme
  -- Moves back to before the first cluster, without re-analysing the text
, member procedure Reset(self in out nocopy TY_GraphemeIterator)
);
/

create or replace
type body TY_GraphemeIterator as

  static function New(pText varchar2 character set any_cs, pUnit pls_integer default 0) return TY_GraphemeIterator is
  begin
    return TY_GraphemeIterator(P_Grapheme.GraphemeList(pText, pUnit), 0);
  end;

  static function New(pText clob, pUnit pls_integer default 0) return TY_GraphemeIterator is
  begin
    return TY_GraphemeIterator(P_Grapheme.GraphemeList(pText, pUnit), 0);
  end;

  member function HasNext return boolean is
  begin
    return Position < Graphemes.Count;
  end;

  member function Next(self in out nocopy TY_GraphemeIterator) return TY_Grapheme is
  begin
    if Position >= Graphemes.Count then
      raise_application_error(P_Grapheme.C_INDEX_OUT_OF_RANGE, 'No more grapheme clusters');
    end if;
    Position := Position + 1;
    return Graphemes(Position);
  end;

  member procedure Reset(self in out nocopy TY_GraphemeIterator) is
  begin
    Position := 0;
  end;

end;
/
