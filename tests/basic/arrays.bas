DIM A(5), B%(1 TO 3, 1 TO 2), N$(2)
FOR I = 0 TO 5: A(I) = I * I: NEXT
PRINT A(3); A(5)
FOR I = 1 TO 3: FOR J = 1 TO 2: B%(I, J) = I * 10 + J: NEXT: NEXT
PRINT B%(2, 1); B%(3, 2)
N$(0) = "zero": N$(2) = "two"
PRINT N$(0); N$(1); N$(2)
PRINT LBOUND(B%, 2); UBOUND(B%, 1); UBOUND(A)
C(3) = 7: PRINT C(3); C(10)
TYPE Pt
  X AS INTEGER
  Y AS SINGLE
END TYPE
DIM P AS Pt, Q(2) AS Pt
P.X = 3: P.Y = 1.5
Q(1).X = P.X + 1: Q(1).Y = P.Y * 2
PRINT P.X; P.Y; Q(1).X; Q(1).Y
Fill A(): PRINT A(2)
PRINT Sum(A())
REDIM A(10): PRINT A(2); UBOUND(A)
ERASE N$: DIM N$(1 TO 4): N$(4) = "four": PRINT N$(4)
SWAP A(1), A(2)
SUB Fill (V())
  FOR I = LBOUND(V) TO UBOUND(V): V(I) = 9: NEXT
END SUB
FUNCTION Sum (V())
  S = 0
  FOR I = LBOUND(V) TO UBOUND(V): S = S + V(I): NEXT
  Sum = S
END FUNCTION
