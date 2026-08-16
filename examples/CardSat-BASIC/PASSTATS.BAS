10 REM ====== PASSTATS - named arrays over the upcoming passes ======
110 IF PASSOK = 1 THEN GOTO 140
120 PRINT "no pass list - need a satellite, clock and position"
130 END
140 LET N = 8
150 DIM A(8), E(8)
170 LET K = 0
180 FOR I = 0 TO N - 1
190 LET T = PASSAOS(I)
200 IF T <= 0 THEN GOTO 250
210 LET A(K) = T
220 LET E(K) = PASSMAX(I)
230 LET K = K + 1
250 NEXT I
260 IF K > 0 THEN GOTO 290
270 PRINT "no upcoming passes in the window"
280 END
290 PRINT "passes: "; K
310 LET S = 0
320 LET P = 0
330 FOR I = 0 TO K - 1
340 LET S = S + E(I)
350 IF E(I) > P THEN LET P = E(I)
360 NEXT I
370 PRINT "mean max el "; ROUND(S / K); " deg"
380 PRINT "best max el "; ROUND(P); " deg"
400 IF K > 1 THEN GOTO 430
410 PRINT "only one pass - no gaps to report"
420 GOTO 500
430 LET G = 9999
440 FOR I = 1 TO K - 1
450 LET D = A(I) - A(I - 1)
460 IF D < G THEN LET G = D
470 NEXT I
480 PRINT "closest pair "; ROUND(G); " min apart"
500 LET W = 0
510 FOR I = 0 TO K - 1
520 IF E(I) >= 20 THEN LET W = W + 1
530 NEXT I
540 PRINT W; " pass(es) over 20 deg"
580 ERASE A
590 ERASE E
600 END
