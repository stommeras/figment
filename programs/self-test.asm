; Checks the stack, CALL and RET, both LD and ST forms, the shifts, the logic
; operations and the conditional jumps, then fills the screen with 0x0B if
; every check passed or 0x08 if one failed.

        LDI r1, 0x5A
        PUSH r1
        POP r2
        CMP r2, 0x5A
        JNZ fail
        CALL sub
        CMP r3, 0x77
        JNZ fail
        ST r1, [0x1000]
        LDI r4, 0x10
        LDI r5, 0x00
        LD r6, [r4:r5]
        CMP r6, r1
        JNZ fail
        LDI r7, 0x81
        SHL r7          ; r7 is 0x02 and C is 1
        JNC fail
        SHR r7          ; r7 is 0x01 and C is 0
        JC fail
        AND r7, 1
        JZ fail
        XOR r7, 1
        JNZ fail
        OR r7, 0xA5
        LD r8, [0x9000] ; the top bit is ignored, so this reads 0x1000
        OR r7, r8
        CMP r7, 0xFF
        JNZ fail
        LDI r0, 0x0B
        JMP fill

sub:    LDI r3, 0x77
        RET

fail:   LDI r0, 0x08
fill:   LDI r4, 0x40
        LDI r5, 0x00
loop:   ST r0, [r4:r5]
        ADD r5, 1
        ADC r4, 0
        CMP r4, 0x80
        JNZ loop
        HLT
