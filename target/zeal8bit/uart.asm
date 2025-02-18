; SPDX-FileCopyrightText: 2022 Zeal 8-bit Computer <contact@zeal8bit.com>
;
; SPDX-License-Identifier: Apache-2.0

        INCLUDE "errors_h.asm"
        INCLUDE "drivers_h.asm"
        INCLUDE "pio_h.asm"
        INCLUDE "uart_h.asm"
        INCLUDE "interrupt_h.asm"

        ; Default value for other pins than UART ones
        ; This is used to output a value on the UART without sending garbage
        ; on the other lines (mainly I2C)
        DEFC PINS_DEFAULT_STATE = IO_PIO_SYSTEM_VAL & ~(1 << IO_UART_TX_PIN)

        SECTION KERNEL_DRV_TEXT
        ; PIO has been initialized before-hand, no need to perform anything here
uart_init:
        ld a, UART_BAUDRATE_DEFAULT
        ld (_uart_baudrate), a
        ; Currently, the driver doesn't need to do anything special for open, close or deinit
uart_open:
uart_close:
uart_deinit:
        ; Return ERR_SUCCESS
        xor a
        ret

        ; Perform an I/O requested by the user application.
        ; For the UART, the command number lets us set the baudrate for receiving and sending.
        ; Parameters:
        ;       B - Dev number the I/O request is performed on.
        ;       C - Command macro, any of the following macros:
        ;           * UART_SET_BAUDRATE
        ;       E - Any of the following macro:
        ;           * UART_BAUDRATE_57600
        ;           * UART_BAUDRATE_38400
        ;           * UART_BAUDRATE_19200
        ;           * UART_BAUDRATE_9600
        ; Returns:
        ;       A - ERR_SUCCESS on success, error code else
        ; Alters:
        ;       A, BC, DE, HL
uart_ioctl:
        ; Check that the command number is correct
        ld a, c
        cp UART_SET_BAUDRATE
        jr nz, uart_ioctl_not_supported
        ; Command is correct, check that the parameter is correct
        ld a, e
        cp UART_BAUDRATE_57600
        jr z, uart_ioctl_valid
        cp UART_BAUDRATE_38400
        jr z, uart_ioctl_valid
        cp UART_BAUDRATE_19200
        jr z, uart_ioctl_valid
        cp UART_BAUDRATE_9600
        jr z, uart_ioctl_valid
uart_ioctl_not_supported:
        ld a, ERR_NOT_SUPPORTED
        ret
uart_ioctl_valid:
        ld (_uart_baudrate), a
        ; Optimization for success
        xor a
        ret


        ; Read bytes from the UART.
        ; Parameters:
        ;       DE - Destination buffer, smaller than 16KB, not cross-boundary, guaranteed to be mapped.
        ;       BC - Size to read in bytes. Guaranteed to be equal to or smaller than 16KB.
        ;       Top of stack: 32-bit offset. MUST BE POPPED IN THIS FUNCTION.
        ;                     Always 0 in case of drivers.
        ; Returns:
        ;       A  - ERR_SUCCESS if success, error code else
        ;       BC - Number of bytes read.
        ; Alters:
        ;       This function can alter any register.
uart_read:
        ; We need to clean the stack as it has a 32-bit value
        pop hl
        pop hl
        ; Prepare the buffer to receive in HL
        ex de, hl
        ; Put the baudrate in D
        ld a, (_uart_baudrate)
        ld d, a
        jp uart_receive_bytes

uart_write:
        pop hl
        pop hl
        ; Prepare the buffer to send in HL
        ex de, hl
        ; Put the baudrate in D
        ld a, (_uart_baudrate)
        ld d, a
        jp uart_send_bytes



        ; No such thing as seek for the UART
uart_seek:
        ld a, ERR_NOT_SUPPORTED
        ret


        ; Send a sequences of bytes on the UART, with a given baudrate
        ; Parameters:
        ;   HL - Pointer to the sequence of bytes
        ;   BC - Size of the sequence
        ;   D -  Baudrate
        ; Returns:
        ;   A - ERR_SUCCESS
        ; Alters:
        ;   A, BC, HL
uart_send_bytes:
        ; Check that the length is not 0
        ld a, b
        or c
        ret z
_uart_send_next_byte:
        ld a, (hl)
        push bc
        ; Enter a critical section (disable interrupts) only when sending a byte.
        ; We must not block the interrupts for too long.
        ; TODO: Add a configuration for this?
        ENTER_CRITICAL()
        call uart_send_byte
        EXIT_CRITICAL()
        pop bc
        inc hl
        dec bc
        ld a, b
        or c
        jp nz, _uart_send_next_byte
        ; Finished sending
        ret

        ; Send a single byte on the UART
        ; Parameters:
        ;   A - Byte to send
        ;   D - Baudrate
        ; Alters:
        ;   A, BC
uart_send_byte:
        ; Shift B to match TX pin
        ASSERT(IO_UART_TX_PIN <= 7)
        REPT IO_UART_TX_PIN
        rlca
        ENDR
        ; Byte to send in C
        ld c, a
        ; 8 bits in B
        ld b, 8
        ; Start bit, set TX pin to 0
        ld a, PINS_DEFAULT_STATE
        out (IO_PIO_SYSTEM_DATA), a
        ; The loop considers that all bits went through the "final"
        ; dec b + jp nz, which takes 14 T-states, but coming from here, we
        ; haven't been through these, so we are a bit too early, let's wait
        ; 14 T-states too.
        jp $+3 
        nop
        ; For each baudrate, we have to wait N T-states in TOTAL:
        ; Baudrate 57600 => (D = 0)  => 173.6  T-states (~173 +  0 * 87)
        ; Baudrate 38400 => (D = 1)  => 260.4  T-states (~173 +  1 * 87)
        ; Baudrate 19200 => (D = 4)  => 520.8  T-states (~173 +  4 * 87)
        ; Baudrate 9600  => (D = 10) => 1041.7 T-states (~173 + 10 * 87)
        ; Wait N-X T-States inside the routine called, before sending next bit, where X is:
        ;            17 (`call` T-states)
        ;          + 4 (`ld` T-states)
        ;          + 8 (`rrc b` T-states)
        ;          + 7 (`and` T-states)
        ;          + 7 (`or` T-states)
        ;          + 12 (`out (c), a` T-states)
        ;          + 14 (dec + jp)
        ;          = 69 T-states
        ; Inside the routine, we have to wait (173 - 69) + D * 87 T-states = 104 + D * 87
uart_send_byte_next_bit:
        call wait_104_d_87_tstates
        ; Put the byte to send in A
        ld a, c
        ; Shift B to prepare next bit
        rrc c
        ; Isolate the bit to send
        and 1 << IO_UART_TX_PIN
        ; Or with the default pin value to not modify I2C
        or PINS_DEFAULT_STATE
        ; Output the bit
        out (IO_PIO_SYSTEM_DATA), a
        ; Check if we still have some bits to send. Do not use djnz,
        ; it adds complexity to the calculation, use jp which always uses 10 T-states
        dec b
        jp nz, uart_send_byte_next_bit
        ; Output the stop bit, but before, for the same reasons as the start, we have to wait the same
        ; amount of T-states that is present before th "out" from the loop: 43 T-states
        call wait_104_d_87_tstates
        ld a, IO_PIO_SYSTEM_VAL
        ; Wait 19 T-states now
        jr $+2
        ld c, 0
        ; Output the bit
        out (IO_PIO_SYSTEM_DATA), a
        ; Output some delay after the stop bit too
        call wait_104_d_87_tstates
        ret

        ; Receive a sequences of bytes on the UART.
        ; Parameters:
        ;   HL - Pointer to the sequence of bytes
        ;   BC - Size of the sequence
        ;   D - Baudrate (0: 57600, 1: 38400, 4: 19200, 10: 9600, ..., from uart_h.asm)
        ; Returns:
        ;   A - ERR_SUCCESS
        ; Alters:
        ;   A, BC, HL
uart_receive_bytes:
        ; Check that the length is not 0
        ld a, b
        or c
        ret z
        ; TODO: Implement a configurable timeout is ms, or a flag for blocking/non-blocking mode,
        ; or an any-key-pressed-aborts-transfer action.
        ; At the moment, block until we receive everything.
        ENTER_CRITICAL()
        ; Length is not 0, we can continue
_uart_receive_next_byte:
        push bc
        call uart_receive_byte
        pop bc
        ld (hl), a
        inc hl
        dec bc
        ld a, b
        or c
        jp nz, _uart_receive_next_byte
        ; Finished receiving, return
        EXIT_CRITICAL()
        ret

        ; Receive a byte on the UART with a given baudrate.
        ; Parameters:
        ;   D - Baudrate
        ; Returns:
        ;   A - Byte received
        ; Alters:
        ;   A, B, E
uart_receive_byte:
        ld e, 8
        ; A will contain the data read from PIO
        xor a
        ; B will contain the final value
        ld b, a
        ; RX pin must be high (=1), before receiving
        ; the start bit, check this state.
        ; If the line is not high, then a transfer is ocurring
        ; or a problem is happening on the line
uart_receive_wait_for_idle_anybaud:
        in a, (IO_PIO_SYSTEM_DATA)
        bit IO_UART_RX_PIN, a
        jp z, uart_receive_wait_for_idle_anybaud
        ; Delay the reception
        jp $+3
        bit 0, a
uart_receive_wait_start_bit_anybaud:
        in a, (IO_PIO_SYSTEM_DATA)
        ; We can use AND and save one T-cycle, but this needs to be time accurate
        ; So let's keep BIT.
        bit IO_UART_RX_PIN, a
        jp nz, uart_receive_wait_start_bit_anybaud
        ; Delay the reception
        ld a, r     ; For timing
        ld a, r     ; For timing
        ; Add 44 T-States (for 57600 baudrate)
        ; This will let us read the bits incoming at the middle of their period
        jr $+2      ; For timing
        ld a, (hl)  ; For timing
        ld a, (hl)  ; For timing
        ; Check baudrate, if 0 (57600)
        ; Skip the wait_tstates_after_start routine
        ld a, d
        or a
        jp z, uart_receive_wait_next_bit_anybaud
        ; In case we are not in baudrate 57600,
        ; BAUDRATE * 86 - 17 (CALL)
        call wait_tstates_after_start
uart_receive_wait_next_bit_anybaud:
        ; Wait for bit 0
        ; Wait 174 T-states in total for 57600
        ; Where X = 174
        ;           - 17 (CALL T-States)
        ;           - 12 (IN b, (c) T-states)
        ;           - 8 (BIT)
        ;           - 8 (RRC B)
        ;           - 4 (DEC)
        ;           - 10 (JP)
        ;           - 18 (DEBUG/PADDING instructions)
        ;           - 10 (JP)
        ;       X = 105 - 18 = 87 T-states
        ; For any baudrate, wait 87 + baudrate * 86
        call wait_tstates_next_bit
        in a, (IO_PIO_SYSTEM_DATA)
        jp $+3      ; For timing
        bit 0, a    ; For timing
        bit IO_UART_RX_PIN, a
        jp z, uart_received_no_next_bit_anybaud
        inc b
uart_received_no_next_bit_anybaud:
        rrc b
        dec e
        jp nz, uart_receive_wait_next_bit_anybaud
        ; Set the return value in A
        ld a, b
        ret

        ; In case we are not in baudrate 57600, we have to wait about BAUDRATE * 86 - 17
        ; Parameters:
        ;   A - Baudrate
        ;   D - Baudrate
wait_tstates_after_start:
        ; For timing (50 T-states)
        ex (sp), hl
        ex (sp), hl
        bit 0, a
        nop
        ; Really needed
        dec a
        jp nz, wait_tstates_after_start
        ; 10 T-States
        ret

        ; Routine to wait 104 + D * 87 T-states
        ; A can be altered
wait_104_d_87_tstates:
        ; We need to wait 17 T-states more than in the routine below, let's wait and fall-through
        ld a, i
        bit 0, a
        ; After receiving a bit, we have to wait:
        ; 87 + baudrate * 86
        ; Parameters:
        ;   D - Baudrate
wait_tstates_next_bit:
        ld a, d
        or a
        jp z, wait_tstates_next_bit_87_tstates
wait_tstates_next_bit_loop:
        ; This loop shall be 86 T-states long
        ex (sp), hl
        ex (sp), hl
        push af
        ld a, (0)
        pop af
        ; 4 T-states
        dec a
        ; 10 T-states
        jp nz, wait_tstates_next_bit_loop
        ; Total = 2 * 19 + 11 + 13 + 10 + 4 + 10 = 86 T-states
wait_tstates_next_bit_87_tstates:
        ex (sp), hl
        ex (sp), hl
        push hl
        pop hl
        ret


        SECTION DRIVER_BSS
_uart_baudrate: DEFS 1

        SECTION KERNEL_DRV_VECTORS
NEW_DRIVER_STRUCT("SER0", \
                  uart_init, \
                  uart_read, uart_write, \
                  uart_open, uart_close, \
                  uart_seek, uart_ioctl, \
                  uart_deinit)