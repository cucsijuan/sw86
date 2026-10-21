DIM S$(200)
FOR R = 1 TO 30
  FOR I = 1 TO 200
    S$(I) = STRING$(20 + (I MOD 7), CHR$(65 + (I + R) MOD 26)) + STR$(I)
  NEXT
NEXT
OK = -1
FOR I = 1 TO 200
  E$ = STRING$(20 + (I MOD 7), CHR$(65 + (I + 30) MOD 26)) + STR$(I)
  IF S$(I) <> E$ THEN OK = 0
NEXT
PRINT OK; LEN(S$(200)); FRE("") > 1000
PRINT Deep(200)
FOR I = 1 TO 30: PRINT I: NEXT
FUNCTION Deep (N)
  IF N = 0 THEN Deep = 0 ELSE Deep = 1 + Deep(N - 1)
END FUNCTION
