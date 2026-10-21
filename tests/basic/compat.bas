DECLARE SUB Fill (B() AS Spot)
DECLARE FUNCTION Ask# (R, C)
DECLARE FUNCTION Half (N!)
DEFINT A-Z
'$DYNAMIC
TYPE Spot
  XC AS INTEGER
  YC AS INTEGER
END TYPE
CONST UP = 1, OFF = 0, YES = NOT OFF
DIM SHARED Place(1 TO 2), Big&(x), Mode
DEF FnDie (N) = INT(RND(1) * N) + 1
ON ERROR GOTO BadMode
Mode = 9
SCREEN Mode
ON ERROR GOTO 0
SCREEN 0
PRINT "mode"; Mode
REDIM Big&(2)
RESTORE Pic
FOR I = 0 TO 2: READ Big&(I): NEXT I
PRINT Big&(0); Big&(2)
DIM Spots(0 TO 5) AS Spot
Fill Spots()
PRINT Spots(3).XC; Spots(3).YC; Place(2)
PRINT Ask#(1, 2); Half(5); Half(4.5)
T = FnDie(6): PRINT T >= 1 AND T <= 6
FOR C# = 0 TO 1 STEP .25: N = N + 1: NEXT C#: PRINT N
K$ = "7"
SELECT CASE K$
  CASE "0" TO "9": PRINT "digit"
  CASE CHR$(13): PRINT "enter"
  CASE ELSE: PRINT "other"
END SELECT
R = (2.5# * 10) MOD 4: PRINT R
PRINT LTRIM$(STR$(12)) + ">Score<" + LTRIM$(STR$(3))
END
BadMode:
  Mode = 1
  RESUME
Pic:
DATA 327686, -252645316, 60
SUB Fill (B() AS Spot)
  FOR I = LBOUND(B) TO UBOUND(B)
    B(I).XC = I * 10: B(I).YC = FnDie(1) + I
  NEXT
  Place(2) = B(5).XC
END SUB
FUNCTION Ask# (R, C)
  Ask# = R + C / 4
END FUNCTION
FUNCTION Half (N!)
  IF Mode = 1 THEN Half = CINT(N! / 2 + .1) ELSE Half = CINT(N!)
END FUNCTION
