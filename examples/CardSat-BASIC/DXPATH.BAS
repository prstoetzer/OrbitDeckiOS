10 REM ====== DXPATH - path to a DXCC entity, with input ======
20 REM Demonstrates the PRE-RUN INPUT FORM (0.9.71).
110 INPUT "DXCC code"; C
120 INPUT "Your note"; N$
130 IF POSOK = 1 THEN GOTO 160
140 PRINT "no QTH set - Settings > Location"
150 END
160 IF C > 0 THEN GOTO 190
170 PRINT "enter a DXCC entity code, e.g. 291"
180 END
190 REM DXCC$ names it; DXCCLAT/DXCCLON give its reference point.
200 LET A$ = DXCC$(C)
210 IF LEN(A$) > 0 THEN GOTO 240
220 PRINT "unknown entity code "; C
230 END
240 LET T = DXCCLAT(C)
250 LET G = DXCCLON(C)
280 LET D = GCDIST(MYLAT, MYLON, T, G)
290 LET B = GCAZ(MYLAT, MYLON, T, G)
300 PRINT "Path to "; A$
310 PRINT "  grid   "; GRID$(T, G)
320 PRINT "  bearing"; ROUND(B); " deg"
330 PRINT "  range  "; ROUND(D); " km"
350 LET L = B + 180
360 IF L >= 360 THEN LET L = L - 360
370 PRINT "  long   "; ROUND(L); " deg  "; ROUND(40008 - D); " km"
390 PRINT "  FSPL   "; ROUND(FSPL(14.1, D)); " dB at 14.1 MHz"
400 IF LEN(N$) = 0 THEN GOTO 420
410 PRINT "note: "; N$
420 PRINT
430 PRINT "at "; TIME$; " on "; DATE$
440 END
