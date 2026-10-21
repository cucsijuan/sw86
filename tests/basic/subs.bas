DECLARE SUB Show (A$, N%)
DECLARE FUNCTION Twice% (X%)
DEFINT A-Z
CONST LIMIT = 3, NAME$ = "cos"
CONST FALSE = 0, TRUE = NOT FALSE
DIM SHARED Total
Show "x", 2
PRINT Twice(21)
PRINT Fact&(10)
Total = 5: AddTo 7: PRINT Total
V = 1: Bump V: PRINT V
Bump (V): PRINT V
CALL Bump(V): PRINT V
PRINT LIMIT; NAME$; TRUE; FALSE
PRINT Greet$("Ana")
DEF FnSq (Q) = Q * Q
PRINT FnSq(9)
PRINT Add3(Add3(1, 2, 3), Twice(Add3(1, 1, 1)), FnSq(2))
SUB Show (A$, N%)
  FOR I = 1 TO N%: PRINT A$;: NEXT
  PRINT
END SUB
FUNCTION Twice% (X%)
  Twice% = X% * 2
END FUNCTION
FUNCTION Fact& (N)
  IF N <= 1 THEN Fact& = 1 ELSE Fact& = N * Fact&(N - 1)
END FUNCTION
SUB AddTo (N)
  Total = Total + N
END SUB
SUB Bump (N)
  N = N + 1
END SUB
FUNCTION Greet$ (Who$)
  Greet$ = "Hi " + Who$ + "!"
  IF Who$ = "" THEN EXIT FUNCTION
END FUNCTION
FUNCTION Add3 (A, B, C)
  Add3 = A + B + C
END FUNCTION
