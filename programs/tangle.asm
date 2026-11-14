; Two players steer curving lines around a walled field, and a line that runs into
; anything stops. Player 1 turns with Left and Right, player 2 with A and B.
; Start begins a round. The one still moving when the other stops gets a point,
; and the first to 5 wins the match. Now and then a line leaves a short gap to slip through.
;
; Each head keeps its position as 8.8 fixed point, a whole pixel and a fraction,
; and turns through 32 directions. A head only acts on a step that takes it to a new pixel.
; It reads that pixel off the screen, so the screen is the only map.
; A diagonal step also takes the corner pixel on the x side, so every line is 4-connected
; and two lines can't pass through each other where they cross on a diagonal.

KEYS = 0x3F00
BEEP = 0x3F01
RAND = 0x3F02
FRAME = 0x3F03
SCREEN = 0x4000
FIELD = 0x4400                  ; screen row 8, below the status line

; The player being worked on. load_player copies a player here and store_player copies it back.
; The tangle tests in src/asm.zig read the players at P1 and P2 with these offsets from CUR.
CUR = 0x3000
CUR_X_LO = 0x3000
CUR_X_HI = 0x3001               ; the head's pixel column
CUR_Y_LO = 0x3002
CUR_Y_HI = 0x3003               ; the head's pixel row
CUR_DIR = 0x3004                ; 0 to 31, clockwise from right
CUR_TURN_WAIT = 0x3005          ; the steps left before a held key turns again
CUR_ALIVE = 0x3006
CUR_MOVED = 0x3007              ; 1 if this step took the head to a new pixel
CUR_COLOR = 0x3008
CUR_LEFT = 0x3009               ; the key that turns left
CUR_RIGHT = 0x300A
CUR_OLD_X = 0x300B              ; the pixel the head left on its last move
CUR_OLD_Y = 0x300C
CUR_CORNER_X = 0x300D           ; the corner pixel of that move, or the new head after a straight one
CUR_CORNER_Y = 0x300E
CUR_GAP = 0x300F                ; the moves left in the current gap
CUR_SCORE = 0x3010
PLAYER_BYTES = 17
P1 = 0x3020                     ; P1 and P2 share the page of CUR, so copies change only low bytes
P2 = 0x3040

STATE = 0x3060
KEYS_BEFORE = 0x3061            ; the keys held last frame
PAUSE = 0x3062                  ; the frames left before the next round
GAP_ODDS = 0x3063               ; a gap starts on a move when a random byte is below this
BEEP_FRAMES = 0x3064            ; the frames left on the current beep

READY = 0                       ; the states
PLAYING = 1
OVER = 2
MATCH_OVER = 3

STEPS = 1                       ; the moves each frame. Each moves under half a pixel
TURN_STEPS = 2                  ; the steps between turns while a key is held. At 1, a head
                                ; could wobble back onto the pixel it just left and stop
PAUSE_FRAMES = 60
WIN_SCORE = 5
GAP_CHANCE = 4                  ; out of 256 moves
GAP_MOVES = 4

BLANK = 10                      ; the glyphs after the digits
BAR = 11

LEFT = 0b0000_0100
RIGHT = 0b0000_1000
KEY_A = 0b0001_0000
KEY_B = 0b0010_0000
START = 0b0100_0000

BLACK = 0x0
NAVY = 0x1
GRAY = 0x6
YELLOW = 0xA
BLUE = 0xC

NOTE_CRASH = 30
NOTE_POINT = 76
NOTE_WIN = 84

main:   LDI r0, GAP_CHANCE
        ST r0, [GAP_ODDS]
        CALL new_match

frame:  CALL tick_beep
        LD rC, [KEYS]           ; rC = the keys held
        LD r0, [KEYS_BEFORE]
        ST rC, [KEYS_BEFORE]
        XOR r0, 0xFF
        MOV rD, rC              ; rD = the keys pressed this frame and not the last
        AND rD, r0
        LD r0, [STATE]
        CMP r0, PLAYING
        JZ .play
        CMP r0, OVER
        JZ .over
        AND rD, START
        JZ .done
        CMP r0, MATCH_OVER
        JNZ .go
        CALL new_match
        JMP .done
.go:    LDI r0, PLAYING
        ST r0, [STATE]
        JMP .done
.over:  LD r0, [PAUSE]
        SUB r0, 1
        ST r0, [PAUSE]
        JNZ .done
        CALL new_round
        JMP .done
.play:  LDI r0, STEPS
.step:  PUSH r0
        CALL step
        POP r0
        LD r1, [STATE]
        CMP r1, PLAYING
        JNZ .done
        SUB r0, 1
        JNZ .step
.done:  ST r0, [FRAME]
        JMP frame

new_match:
        LDI rB, lo(P1)
        LDI r1, YELLOW
        LDI r2, LEFT
        LDI r3, RIGHT
        CALL setup
        LDI rB, lo(P2)
        LDI r1, BLUE
        LDI r2, KEY_A
        LDI r3, KEY_B
        CALL setup
        JMP new_round

; Gives player rB color r1, left key r2, right key r3 and no points.
setup:  CALL load_player
        ST r1, [CUR_COLOR]
        ST r2, [CUR_LEFT]
        ST r3, [CUR_RIGHT]
        LDI r0, 0
        ST r0, [CUR_SCORE]
        JMP store_player

; Clears the field and puts both heads on it, at least 16 pixels from the border
; and, in one direction or the other, from each other.
new_round:
        CALL clear_field
        CALL random_spot
        MOV r3, r1
        MOV r4, r2
        LDI rB, lo(P1)
        CALL place
.again: CALL random_spot
        MOV r0, r1              ; far enough if x or y differs by 16 or more
        SUB r0, r3
        ADD r0, 15
        CMP r0, 31
        JNC .far
        MOV r0, r2
        SUB r0, r4
        ADD r0, 15
        CMP r0, 31
        JC .again
.far:   LDI rB, lo(P2)
        CALL place
        LDI r0, READY
        ST r0, [STATE]
        JMP draw_status

; r1 = a random column from 32 to 95 and r2 = a random row from 36 to 99.
random_spot:
        LD r1, [RAND]
        AND r1, 63
        ADD r1, 32
        LD r2, [RAND]
        AND r2, 63
        ADD r2, 36
        RET

; Puts player rB's head at r1, r2, facing a random way, and draws it. Keeps r3 and r4.
place:  CALL load_player
        ST r1, [CUR_X_HI]
        ST r2, [CUR_Y_HI]
        ST r1, [CUR_OLD_X]
        ST r2, [CUR_OLD_Y]
        ST r1, [CUR_CORNER_X]
        ST r2, [CUR_CORNER_Y]
        LDI r0, 0x80
        ST r0, [CUR_X_LO]
        ST r0, [CUR_Y_LO]
        LD r0, [RAND]
        AND r0, 31
        ST r0, [CUR_DIR]
        LDI r0, 0
        ST r0, [CUR_TURN_WAIT]
        ST r0, [CUR_MOVED]
        ST r0, [CUR_GAP]
        LDI r0, 1
        ST r0, [CUR_ALIVE]
        LD r0, [CUR_COLOR]
        CALL pixel_address
        ST r0, [r5:r6]
        JMP store_player

; Moves both heads, then draws them, so neither sees the other's pixels from the same step.
step:   LDI rB, lo(P1)
        CALL move
        LDI rB, lo(P2)
        CALL move
        CALL meet
        LDI rB, lo(P1)
        CALL draw_head
        LDI rB, lo(P2)
        CALL draw_head

; Ends the round if a head stopped, and gives the other a point if it didn't.
        LDI rB, lo(P1)
        CALL load_player
        LD r1, [CUR_ALIVE]
        LDI rB, lo(P2)
        CALL load_player
        LD r2, [CUR_ALIVE]
        MOV r0, r1
        AND r0, r2
        JNZ .end
        LDI r0, OVER
        ST r0, [STATE]
        LDI r0, PAUSE_FRAMES
        ST r0, [PAUSE]
        LDI rB, lo(P1)
        CMP r1, 0
        JNZ .point
        LDI rB, lo(P2)
        CMP r2, 0
        JNZ .point
        LDI r0, NOTE_CRASH
        LDI r1, 20
        JMP beep
.point: CALL load_player
        LD r1, [CUR_SCORE]
        ADD r1, 1
        ST r1, [CUR_SCORE]
        CALL store_player
        LDI r0, NOTE_POINT
        CMP r1, WIN_SCORE
        LDI r1, 10
        JNZ .beep
        LDI r0, MATCH_OVER
        ST r0, [STATE]
        LDI r0, NOTE_WIN
        LDI r1, 40
.beep:  CALL beep
        JMP draw_status
.end:   RET

; Turns player rB with the keys in rC, moves it, and stops it if its new pixels are taken.
; Keeps rB to rD.
move:   CALL load_player
        LDI r0, 0
        ST r0, [CUR_MOVED]
        LD r0, [CUR_ALIVE]
        CMP r0, 0
        JZ store_player
        LD r1, [CUR_LEFT]
        AND r1, rC
        LD r2, [CUR_RIGHT]
        AND r2, rC
        CMP r1, 0               ; no turn unless exactly one of the two keys is held
        JZ .right_only
        CMP r2, 0
        JNZ .no_turn
        JMP .held
.right_only:
        CMP r2, 0
        JZ .no_turn
.held:
        LD r0, [CUR_TURN_WAIT]
        CMP r0, 0
        JZ .turn
        SUB r0, 1
        ST r0, [CUR_TURN_WAIT]
        JMP .go
.turn:  LDI r0, TURN_STEPS
        SUB r0, 1
        ST r0, [CUR_TURN_WAIT]
        LD r0, [CUR_DIR]
        ADD r0, 1
        CMP r1, 0
        JZ .dir
        SUB r0, 2
.dir:   AND r0, 31
        ST r0, [CUR_DIR]
        JMP .go
.no_turn:
        LDI r0, 0
        ST r0, [CUR_TURN_WAIT]

.go:    LD r0, [CUR_DIR]        ; r3 = sin and r4 = cos of the direction
        LDI r5, hi(sine)
        LDI r6, lo(sine)
        ADD r6, r0
        ADC r5, 0
        LD r3, [r5:r6]
        ADD r6, 8
        ADC r5, 0
        LD r4, [r5:r6]
        LD r1, [CUR_X_HI]       ; r1, r2 = the head before the move
        LD r2, [CUR_Y_HI]
        LDI r7, hi(CUR_X_LO)
        LDI r8, lo(CUR_X_LO)
        CALL add_signed
        LDI r8, lo(CUR_Y_LO)
        MOV r4, r3
        CALL add_signed
        LD r3, [CUR_X_HI]       ; r3, r4 = the head after it
        LD r4, [CUR_Y_HI]
        CMP r1, r3
        JNZ .new
        CMP r2, r4
        JZ store_player

.new:   LDI r0, 1
        ST r0, [CUR_MOVED]
        ST r1, [CUR_OLD_X]
        ST r2, [CUR_OLD_Y]
        ST r3, [CUR_CORNER_X]
        ST r4, [CUR_CORNER_Y]
        CMP r1, r3
        JZ .check
        CMP r2, r4
        JZ .check
        ST r2, [CUR_CORNER_Y]   ; a diagonal step, so the corner is the new column on the old row
.check: LD r1, [CUR_CORNER_X]
        LD r2, [CUR_CORNER_Y]
        CALL blocked
        JNZ .stop
        MOV r1, r3
        MOV r2, r4
        CALL blocked
        JZ store_player
.stop:  LDI r0, 0
        ST r0, [CUR_ALIVE]
        JMP store_player

; Stops both heads if their new pixels overlap, since neither has drawn them yet.
meet:   LDI rB, lo(P1)
        CALL targets
        JZ .end
        MOV r7, r1
        MOV r8, r2
        MOV r9, r3
        MOV rA, r4
        LDI rB, lo(P2)
        CALL targets
        JZ .end
        CMP r7, r1
        JNZ .a
        CMP r8, r2
        JZ .both
.a:     CMP r7, r3
        JNZ .b
        CMP r8, r4
        JZ .both
.b:     CMP r9, r1
        JNZ .c
        CMP rA, r2
        JZ .both
.c:     CMP r9, r3
        JNZ .end
        CMP rA, r4
        JNZ .end
.both:  LDI rB, lo(P1)
        CALL stop
        LDI rB, lo(P2)
        JMP stop
.end:   RET

; r1, r2 = the corner and r3, r4 = the new head of player rB, and Z is clear
; if it is alive and moved this step. Uses r0, r5, r6, rE and rF.
targets:
        CALL load_player
        LD r1, [CUR_CORNER_X]
        LD r2, [CUR_CORNER_Y]
        LD r3, [CUR_X_HI]
        LD r4, [CUR_Y_HI]
        LD r0, [CUR_ALIVE]
        LD r5, [CUR_MOVED]
        AND r0, r5
        RET

; Stops player rB. Uses r0, r5, r6, rE and rF.
stop:   CALL load_player
        LDI r0, 0
        ST r0, [CUR_ALIVE]
        JMP store_player

; Adds the signed byte r4 to the 8.8 number at r7:r8, low byte first. Keeps r1 to r4.
; Uses r0, r6 and r9.
add_signed:
        MOV r9, r8              ; r7:r9 = the high byte, set up before ADD sets the carry
        ADD r9, 1
        LDI r6, 0               ; r6 = r4's sign spread over a byte
        MOV r0, r4
        AND r0, 0x80
        JZ .add
        LDI r6, 0xFF
.add:   LD r0, [r7:r8]
        ADD r0, r4
        ST r0, [r7:r8]
        LD r0, [r7:r9]
        ADC r0, r6
        ST r0, [r7:r9]
        RET

; Clears Z if pixel r1, r2 is taken. Keeps r1 to r4. Uses r0, r5 and r6.
blocked:
        CALL pixel_address
        LD r0, [r5:r6]
        CMP r0, NAVY
        RET

; Draws the new pixels of player rB if it moved this step. In a gap it draws only the head
; and erases the pixel behind, which no other head can be on. Keeps rB to rD.
draw_head:
        CALL load_player
        LD r0, [CUR_ALIVE]
        LD r1, [CUR_MOVED]
        AND r0, r1
        JZ store_player
        LD r0, [CUR_GAP]
        CMP r0, 0
        JZ .line
        SUB r0, 1
        ST r0, [CUR_GAP]
        LDI r0, NAVY
        LD r1, [CUR_OLD_X]
        LD r2, [CUR_OLD_Y]
        CALL pixel_address
        ST r0, [r5:r6]
        JMP .head
.line:  LD r0, [RAND]
        LD r1, [GAP_ODDS]
        CMP r0, r1
        JNC .corner
        LDI r0, GAP_MOVES
        ST r0, [CUR_GAP]
.corner:
        LD r0, [CUR_COLOR]
        LD r1, [CUR_CORNER_X]
        LD r2, [CUR_CORNER_Y]
        CALL pixel_address
        ST r0, [r5:r6]
.head:  LD r0, [CUR_COLOR]
        LD r1, [CUR_X_HI]
        LD r2, [CUR_Y_HI]
        CALL pixel_address
        ST r0, [r5:r6]
        JMP store_player

; Plays note r0 for r1 frames.
beep:   ST r0, [BEEP]
        ST r1, [BEEP_FRAMES]
        RET

tick_beep:
        LD r0, [BEEP_FRAMES]
        CMP r0, 0
        JZ .end
        SUB r0, 1
        ST r0, [BEEP_FRAMES]
        JNZ .end
        ST r0, [BEEP]
.end:   RET

; Draws each player's score in its color at either end of the status line,
; and between them a bar in the winner's color once the match is over.
draw_status:
        LDI rB, lo(P1)
        LDI r7, 0
        CALL draw_score
        LDI rB, lo(P2)
        LDI r7, 15
        CALL draw_score
        LD r0, [STATE]
        CMP r0, MATCH_OVER
        JNZ .blank
        LD r0, [CUR_SCORE]      ; CUR holds player 2
        CMP r0, WIN_SCORE
        JZ .won
        LDI rB, lo(P1)
        CALL load_player
.won:   LD r1, [CUR_COLOR]
        LDI r0, BAR
        JMP .bar
.blank: LDI r0, BLANK
.bar:   LDI r7, 2
.tile:  CALL draw_tile
        ADD r7, 1
        CMP r7, 14
        JNZ .tile
        RET

; Draws player rB's score at status tile r7.
draw_score:
        CALL load_player
        LD r0, [CUR_SCORE]
        LD r1, [CUR_COLOR]
        LDI r8, 0
        JMP draw_tile

; Draws glyph r0 in color r1 on black at screen tile r7, r8.
; Keeps r0, r1, r4, r7, r8, rC and rD. Uses r2, r3, r5, r6 and r9 to rB.
; This is the drawing loop from rogue.asm, kept unrolled.
draw_tile:
        LDI r2, BLACK
        MOV rA, r0              ; r9:rA = glyphs + r0 * 8
        SHL rA
        SHL rA
        SHL rA
        LDI r9, hi(glyphs)
        ADD rA, lo(glyphs)
        ADC r9, 0
        MOV r5, r8              ; r5:r6 = SCREEN + r8 * 1024 + r7 * 8
        SHL r5
        SHL r5
        ADD r5, hi(SCREEN)
        MOV r6, r7
        SHL r6
        SHL r6
        SHL r6
        LDI rB, 8
.row:   LD r3, [r9:rA]
        CMP r3, 0
        JZ .blank
        ST r2, [r5:r6]
        SHL r3
        JNC .px0
        ST r1, [r5:r6]
.px0:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px1
        ST r1, [r5:r6]
.px1:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px2
        ST r1, [r5:r6]
.px2:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px3
        ST r1, [r5:r6]
.px3:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px4
        ST r1, [r5:r6]
.px4:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px5
        ST r1, [r5:r6]
.px5:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px6
        ST r1, [r5:r6]
.px6:   ADD r6, 1
        ST r2, [r5:r6]
        SHL r3
        JNC .px7
        ST r1, [r5:r6]
.px7:   ADD r6, 1
        JMP .next
.blank: ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
        ST r2, [r5:r6]
        ADD r6, 1
.next:  SUB r6, 8               ; back to the row start, then down a row
        ADD r6, 128
        ADC r5, 0
        ADD rA, 1
        ADC r9, 0
        SUB rB, 1
        JNZ .row
        RET

; Copies player rB to CUR. Uses r0, r5, r6, rE and rF.
load_player:
        MOV r6, rB
        LDI rE, lo(CUR)
        JMP copy_player

; Copies CUR to player rB. Uses r0, r5, r6, rE and rF.
store_player:
        LDI r6, lo(CUR)
        MOV rE, rB

; Copies a player from low byte r6 to low byte rE of the page of CUR.
copy_player:
        LDI r5, hi(CUR)
        LDI rF, PLAYER_BYTES
.next:  LD r0, [r5:r6]
        ST r0, [r5:rE]
        ADD r6, 1
        ADD rE, 1
        SUB rF, 1
        JNZ .next
        RET

; Fills the field with navy inside a gray border.
clear_field:
        LDI r5, hi(FIELD)
        LDI r6, 0
        LDI r0, NAVY
.fill:  ST r0, [r5:r6]
        ADD r6, 1
        JNZ .fill
        ADD r5, 1
        CMP r5, 0x80
        JNZ .fill
        LDI r0, GRAY
        LDI r1, 0
.row:   LDI r2, 8
        CALL pixel_address
        ST r0, [r5:r6]
        LDI r2, 127
        CALL pixel_address
        ST r0, [r5:r6]
        ADD r1, 1
        CMP r1, 128
        JNZ .row
        LDI r2, 8
.column:
        LDI r1, 0
        CALL pixel_address
        ST r0, [r5:r6]
        LDI r1, 127
        CALL pixel_address
        ST r0, [r5:r6]
        ADD r2, 1
        CMP r2, 128
        JNZ .column
        RET

; r5:r6 = the screen address of pixel r1, r2. Keeps r0 to r4.
pixel_address:
        MOV r5, r2
        SHR r5
        ADD r5, hi(SCREEN)
        MOV r6, r2
        AND r6, 1
        JZ .even
        LDI r6, 0x80
.even:  OR r6, r1
        RET

; round(127 * sin(2 * pi * i / 32)) for i from 0 to 39, so cos(i) is sine[i + 8].
sine:   .byte 0x00, 0x19, 0x31, 0x47, 0x5A, 0x6A, 0x75, 0x7D
        .byte 0x7F, 0x7D, 0x75, 0x6A, 0x5A, 0x47, 0x31, 0x19
        .byte 0x00, 0xE7, 0xCF, 0xB9, 0xA6, 0x96, 0x8B, 0x83
        .byte 0x81, 0x83, 0x8B, 0x96, 0xA6, 0xB9, 0xCF, 0xE7
        .byte 0x00, 0x19, 0x31, 0x47, 0x5A, 0x6A, 0x75, 0x7D

; 8 bytes a glyph, one bit per pixel, top row first: the digits 0 to 9, BLANK and BAR.
glyphs: .byte 0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00
        .byte 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00
        .byte 0x3C, 0x66, 0x06, 0x0C, 0x30, 0x60, 0x7E, 0x00
        .byte 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00
        .byte 0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00
        .byte 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00
        .byte 0x3C, 0x66, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00
        .byte 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00
        .byte 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00
        .byte 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x66, 0x3C, 0x00
        .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        .byte 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00
