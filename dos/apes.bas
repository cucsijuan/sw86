' APES.BAS - Ape Duel, a CucsiCorp CBasic demonstration
'
' Two apes stand on the roofs of a city and throw bananas at each
' other. Each player chooses the angle and the speed of the throw; the
' wind and the gravity do the rest. Run it with: BASIC APES
'
DECLARE SUB Intro ()
DECLARE SUB Setup (P1$, P2$, Goal, Grav!)
DECLARE SUB Pictures ()
DECLARE SUB City ()
DECLARE SUB PlaceApes ()
DECLARE SUB DrawApe (X, Y, Up)
DECLARE SUB Sun (Shocked)
DECLARE SUB Banner (Row, T$)
DECLARE SUB Boom (X, Y, R)
DECLARE SUB Dance (P)
DECLARE SUB ShowScore ()
DECLARE SUB Pause (S!)
DECLARE SUB GameOver ()
DECLARE FUNCTION Throw (P)
DECLARE FUNCTION Fly (P, Ang!, Vel!)
DECLARE FUNCTION AskNum! (Row, Col, Label$)
DEFINT A-Z

TYPE Roof
  X AS INTEGER
  W AS INTEGER
  Y AS INTEGER
END TYPE

CONST FALSE = 0, TRUE = NOT FALSE
CONST SKY = 0, GRASS = 2, FIRE = 4, FUR = 6, DARK = 8, LIGHT = 14
CONST BLACK = 16, WHITE = 15

DIM SHARED Roofs(1 TO 20) AS Roof, Count
DIM SHARED ApeX(1 TO 2), ApeY(1 TO 2), Wins(1 TO 2)
DIM SHARED Gravity!, Wind, SunHit, MaxCol
DIM SHARED ApeUp&(50), ApeDown&(50), Ban&(6), Colors(1 TO 3)
DIM SHARED Names$(1 TO 2)

DEF FnRand (N) = INT(RND(1) * N) + 1

RANDOMIZE TIMER
Intro
Setup Names$(1), Names$(2), Goal, Gravity!
SCREEN 13
PALETTE SKY, 42 * 65536 + 10 * 256 ' a blue sky behind the text too
COLOR WHITE
MaxCol = 40
Colors(1) = 4: Colors(2) = 7: Colors(3) = 3   ' red, gray and teal walls
Pictures
P = 1
DO
  City
  PlaceApes
  Sun FALSE
  ShowScore
  DO
    Hit = Throw(P)
    IF SunHit THEN Sun FALSE
    IF Hit = 0 THEN P = 3 - P
  LOOP UNTIL Hit
  IF Hit = P THEN Winner = 3 - P ELSE Winner = P
  Wins(Winner) = Wins(Winner) + 1
  ShowScore
  Dance Winner
  P = 3 - Winner                    ' the loser starts the next round
LOOP UNTIL Wins(Winner) >= Goal
GameOver
END

' Asks for a number at (Row, Col), typed with the digit keys
FUNCTION AskNum! (Row, Col, Label$)
  LOCATE Row, Col: PRINT Label$;
  T$ = ""
  DO
    LOCATE Row, Col + LEN(Label$): PRINT T$; "_ ";
    DO: K$ = INKEY$: LOOP WHILE K$ = ""
    SELECT CASE K$
      CASE "0" TO "9", "."
        IF LEN(T$) < 5 THEN T$ = T$ + K$
      CASE CHR$(8)
        IF LEN(T$) > 0 THEN T$ = LEFT$(T$, LEN(T$) - 1)
      CASE CHR$(13)
        IF LEN(T$) > 0 THEN EXIT DO
      CASE ELSE
        BEEP
    END SELECT
  LOOP
  LOCATE Row, Col + LEN(Label$): PRINT T$; "  ";
  AskNum! = VAL(T$)
END FUNCTION

' Centers T$ on Row
SUB Banner (Row, T$)
  LOCATE Row, (MaxCol - LEN(T$)) \ 2 + 1
  PRINT T$;
END SUB

' An explosion of radius R that leaves a hole
SUB Boom (X, Y, R)
  PLAY "MBO0L32EFGEFDC"
  FOR I = 1 TO R
    CIRCLE (X, Y), I, FIRE
  NEXT
  FOR I = R TO 0 STEP -1
    CIRCLE (X, Y), I, SKY
    Pause .01
  NEXT
END SUB

' The city: buildings with lit windows, the grass and the wind
SUB City
  CLS
  X = 0: Count = 0
  Slope = FnRand(3)
  H = 40 + FnRand(30)
  DO
    Count = Count + 1
    W = 22 + FnRand(14)
    IF X + W > 319 OR Count = 20 THEN W = 320 - X
    SELECT CASE Slope
      CASE 1: H = H + FnRand(14) - 5
      CASE 2: H = H - FnRand(14) + 5
      CASE ELSE
        IF X < 140 THEN H = H + FnRand(16) - 4 ELSE H = H - FnRand(16) + 4
    END SELECT
    IF H < 25 THEN H = 25
    IF H > 125 THEN H = 125
    Top = 190 - H
    LINE (X, Top)-(X + W - 2, 189), Colors(FnRand(3)), BF
    FOR WY = Top + 3 TO 184 STEP 7
      FOR WX = X + 3 TO X + W - 6 STEP 5
        IF FnRand(4) > 1 THEN C = LIGHT ELSE C = DARK
        LINE (WX, WY)-(WX + 1, WY + 3), C, BF
      NEXT
    NEXT
    Roofs(Count).X = X: Roofs(Count).W = W - 1: Roofs(Count).Y = Top
    X = X + W
  LOOP UNTIL X >= 319
  LINE (0, 190)-(319, 199), GRASS, BF
  Wind = FnRand(11) - 6
  IF FnRand(3) = 1 THEN Wind = Wind * 2
  IF Wind <> 0 THEN
    LINE (160, 195)-(160 + Wind * 4, 195), LIGHT
    IF Wind > 0 THEN D = -2 ELSE D = 2
    LINE (160 + Wind * 4, 195)-(160 + Wind * 4 + D, 193), LIGHT
    LINE (160 + Wind * 4, 195)-(160 + Wind * 4 + D, 197), LIGHT
  END IF
END SUB

' The winner jumps for joy
SUB Dance (P)
  FOR I = 1 TO 4
    PUT (ApeX(P), ApeY(P)), ApeUp&, PSET
    PLAY "MBO2L32EGEC"
    Pause .2
    PUT (ApeX(P), ApeY(P)), ApeDown&, PSET
    Pause .2
  NEXT
END SUB

' An ape in a 12 x 16 box, arms up or down
SUB DrawApe (X, Y, Up)
  LINE (X + 4, Y)-(X + 7, Y + 3), FUR, BF            ' head
  PSET (X + 5, Y + 1), BLACK: PSET (X + 6, Y + 1), BLACK
  LINE (X + 3, Y + 4)-(X + 8, Y + 10), FUR, BF       ' body
  PSET (X + 5, Y + 6), BLACK: PSET (X + 6, Y + 6), BLACK
  LINE (X + 3, Y + 11)-(X + 4, Y + 15), FUR, BF      ' legs
  LINE (X + 7, Y + 11)-(X + 8, Y + 15), FUR, BF
  IF Up THEN                                        ' arms
    LINE (X + 1, Y)-(X + 2, Y + 6), FUR, BF
    LINE (X + 9, Y)-(X + 10, Y + 6), FUR, BF
  ELSE
    LINE (X + 1, Y + 4)-(X + 2, Y + 11), FUR, BF
    LINE (X + 9, Y + 4)-(X + 10, Y + 11), FUR, BF
  END IF
END SUB

' Throws a banana: TRUE (the ape hit) or 0
FUNCTION Fly (P, Ang!, Vel!)
  IF P = 2 THEN Ang! = 180 - Ang!
  R! = Ang! * 3.141593 / 180
  VX! = COS(R!) * Vel!
  VY! = SIN(R!) * Vel!
  PUT (ApeX(P), ApeY(P)), ApeUp&, PSET
  PLAY "MBO2L64CEG"
  X0! = ApeX(P) + 4
  Y0! = ApeY(P) - 7
  Shown = FALSE: Down = FALSE: Victim = 0: T! = 0
  DO
    Pause .02
    X! = X0! + VX! * T! + .25 * Wind * T! * T!
    Y! = Y0! - (VY! * T! - .5 * Gravity! * T! * T!) * .6
    IF Shown THEN PUT (OX, OY), Ban&, XOR: Shown = FALSE
    IF T! > .4 AND NOT Down THEN
      PUT (ApeX(P), ApeY(P)), ApeDown&, PSET
      Down = TRUE
    END IF
    CX = X! + 2: CY = Y! + 2
    IF CX < 0 OR CX > 319 OR CY > 199 THEN EXIT DO
    IF CY >= 0 THEN
      FOR Q = 1 TO 2
        IF CX >= ApeX(Q) AND CX <= ApeX(Q) + 11 THEN
          IF CY >= ApeY(Q) AND CY <= ApeY(Q) + 15 THEN Victim = Q
        END IF
      NEXT
      IF Victim THEN EXIT DO
      IF ABS(CX - 160) < 12 AND CY < 30 THEN
        IF NOT SunHit THEN Sun TRUE
      ELSEIF POINT(CX, CY) <> SKY THEN
        Boom CX, CY, 5
        EXIT DO
      ELSE
        OX = X!: OY = Y!
        PUT (OX, OY), Ban&, XOR
        Shown = TRUE
      END IF
    END IF
    T! = T! + .1
  LOOP
  IF NOT Down THEN PUT (ApeX(P), ApeY(P)), ApeDown&, PSET
  IF Victim THEN
    Boom ApeX(Victim) + 6, ApeY(Victim) + 8, 14
    LINE (ApeX(Victim), ApeY(Victim))-(ApeX(Victim) + 11, ApeY(Victim) + 15), SKY, BF
  END IF
  Fly = Victim
END FUNCTION

SUB GameOver
  SCREEN 0
  MaxCol = 80
  COLOR 15, 1
  CLS
  Banner 8, "G A M E   O V E R"
  COLOR 7, 1
  Banner 11, "Score:"
  Banner 13, Names$(1) + STR$(Wins(1)) + "   " + Names$(2) + STR$(Wins(2))
  COLOR 14, 1
  Banner 22, "Press any key"
  PLAY "MBT160O1L8CDEDCDL4ECC"
  DO: LOOP WHILE INKEY$ = ""
  COLOR 7, 0
  CLS
END SUB

' The title screen
SUB Intro
  SCREEN 0
  MaxCol = 80
  COLOR 15, 1
  CLS
  Banner 5, "A P E   D U E L"
  COLOR 7, 1
  Banner 7, "A CucsiCorp CBasic demonstration"
  Banner 10, "Two apes, a city and a lot of bananas."
  Banner 12, "Throw yours at the other ape: choose the angle"
  Banner 13, "(in degrees) and the speed. Mind the wind!"
  COLOR 14, 1
  Banner 22, "Press any key"
  PLAY "MBT160O2L8CDEDCDL4ECC"
  DO: LOOP WHILE INKEY$ = ""
END SUB

' Waits S! seconds
SUB Pause (S!)
  T! = TIMER
  DO
  LOOP UNTIL TIMER - T! >= S! OR TIMER < T!
END SUB

' The apes and the banana are drawn once and kept with GET
SUB Pictures
  DrawApe 0, 0, FALSE
  GET (0, 0)-(11, 15), ApeDown&
  CLS
  DrawApe 0, 0, TRUE
  GET (0, 0)-(11, 15), ApeUp&
  CLS
  PSET (1, 0), LIGHT                ' the banana
  LINE (0, 1)-(0, 2), LIGHT
  PSET (1, 3), LIGHT
  LINE (2, 4)-(3, 4), LIGHT
  GET (0, 0)-(3, 4), Ban&
  CLS
END SUB

' Each ape on a roof near its end of the city
SUB PlaceApes
  FOR P = 1 TO 2
    IF P = 1 THEN B = FnRand(2) ELSE B = Count - FnRand(2)
    IF B < 1 THEN B = 1
    ApeX(P) = Roofs(B).X + Roofs(B).W \ 2 - 6
    ApeY(P) = Roofs(B).Y - 16
    PUT (ApeX(P), ApeY(P)), ApeDown&, PSET
  NEXT
END SUB

' Names, points to win and gravity
SUB Setup (P1$, P2$, Goal, Grav!)
  COLOR 7, 0
  CLS
  LOCATE 8, 12
  LINE INPUT "Name of player 1 (Enter = 'Ape 1'): "; P1$
  IF P1$ = "" THEN P1$ = "Ape 1" ELSE P1$ = LEFT$(P1$, 10)
  LOCATE 10, 12
  LINE INPUT "Name of player 2 (Enter = 'Ape 2'): "; P2$
  IF P2$ = "" THEN P2$ = "Ape 2" ELSE P2$ = LEFT$(P2$, 10)
  DO
    LOCATE 12, 12
    INPUT "Points to win (Enter = 3)"; G$
    Goal = VAL(G$)
  LOOP UNTIL Goal > 0 OR G$ = ""
  IF Goal = 0 THEN Goal = 3
  LOCATE 14, 12
  INPUT "Gravity in m/s2 (Enter = 9.8)"; G$
  Grav! = VAL(G$)
  IF Grav! <= 0 THEN Grav! = 9.8
END SUB

SUB ShowScore
  LOCATE 1, 1: PRINT Names$(1);
  LOCATE 1, MaxCol - LEN(Names$(2)): PRINT Names$(2);
  Banner 24, LTRIM$(STR$(Wins(1))) + ">Score<" + LTRIM$(STR$(Wins(2)))
END SUB

' The sun, smiling or surprised
SUB Sun (Shocked)
  LINE (144, 4)-(176, 32), SKY, BF
  CIRCLE (160, 18), 8, LIGHT
  PAINT (160, 18), LIGHT, LIGHT
  LINE (147, 18)-(173, 18), LIGHT
  LINE (160, 6)-(160, 30), LIGHT
  LINE (150, 9)-(170, 27), LIGHT
  LINE (150, 27)-(170, 9), LIGHT
  PSET (157, 16), BLACK: PSET (163, 16), BLACK
  IF Shocked THEN
    CIRCLE (160, 21), 2, BLACK
  ELSE
    CIRCLE (160, 17), 5, BLACK, 3.6652, 5.7596
  END IF
  SunHit = Shocked
END SUB

' One turn: the player types the angle and the speed
FUNCTION Throw (P)
  IF P = 1 THEN C = 1 ELSE C = 27
  A! = AskNum!(2, C, "Angle:")
  V! = AskNum!(3, C, "Speed:")
  LOCATE 2, C: PRINT SPACE$(13);
  LOCATE 3, C: PRINT SPACE$(13);
  Throw = Fly(P, A!, V!)
END FUNCTION
