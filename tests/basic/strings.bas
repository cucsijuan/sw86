A$ = "Hello"
B$ = A$ + ", world"
PRINT B$; LEN(B$)
PRINT LEFT$(B$, 3); "|"; RIGHT$(B$, 5); "|"; MID$(B$, 4, 4); "|"; MID$(B$, 8)
PRINT UCASE$("abc"); LCASE$("XyZ"); "|"; LTRIM$("  x  "); "|"; RTRIM$("  x  "); "|"
PRINT INSTR(B$, "o"); INSTR(6, B$, "o"); INSTR(B$, "z")
PRINT ASC("A"); CHR$(66); STR$(42); STR$(-1.5); VAL("12.5") + 1
PRINT SPACE$(3); "x"; STRING$(4, "*"); STRING$(2, 65)
PRINT HEX$(255); " "; OCT$(8)
IF A$ < B$ THEN PRINT "less"
IF "abc" = "abc" THEN PRINT "equal"
C$ = A$: A$ = "changed": PRINT C$; A$
FOR I = 1 TO 200: S$ = S$ + "x": NEXT: PRINT LEN(S$)
FOR I = 1 TO 2000: T$ = STR$(I) + "abcdefghij": NEXT: PRINT T$
SWAP A$, C$: PRINT A$; C$
