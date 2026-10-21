INPUT "Name"; N$
INPUT A, B
LINE INPUT "Line: "; L$
PRINT N$; A + B; L$
INPUT X
PRINT X
DO: K$ = INKEY$: LOOP UNTIL K$ <> ""
PRINT "key "; K$
