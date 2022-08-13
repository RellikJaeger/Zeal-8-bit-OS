        INCLUDE "osconfig.asm"
        INCLUDE "mmu_h.asm"
        INCLUDE "vfs_h.asm"
        INCLUDE "errors_h.asm"
        INCLUDE "disks_h.asm"
        INCLUDE "drivers_h.asm"
        INCLUDE "utils_h.asm"

        EXTERN zos_driver_find_by_name
        EXTERN zos_log_stdout_ready
        EXTERN strncat

        SECTION KERNEL_TEXT

        DEFC VFS_DRIVER_INDICATOR = '#'

        PUBLIC zos_vfs_init
zos_vfs_init:
        ld hl, _vfs_current_dir
        ld (hl), DISK_DEFAULT_LETTER
        inc hl
        ld (hl), ':'
        inc hl
        ld (hl), '/'
        ret

        ; Routine saving the current working directory. It will have no effect if a backup
        ; is already there.
        ; This must be called from the first execvp (from a terminal/console).
        ; Parameter:
        ;       None
        ; Returns:
        ;       None
        ; Alters:
        ;       A, BC, DE, HL
zos_vfs_backup_dir:
        ld a, (_vfs_current_dir_backup)
        ret nz
        ld hl, _vfs_current_dir
        ld de, _vfs_current_dir_backup
        ld bc, CONFIG_KERNEL_PATH_MAX
        ldir
        ret

        ; Routine called after a program exited, all the opened devs need to be closed
        ; The default stdout and stdin need to be restored in the array.
        ; Parameters:
        ;       None
        ; Returns:
        ;       None
        ; Alters:
        ;       A, BC, DE, HL
        PUBLIC zos_vfs_clean
zos_vfs_clean:
        ; Copy back the "current" dir
        ld hl, _vfs_current_dir_backup
        ld de, _vfs_current_dir
        ld bc, CONFIG_KERNEL_PATH_MAX
        ldir
        ; Clean the backup
        xor a
        ld (_vfs_current_dir_backup), a
        ; Close all the opened devs, even stdout and stdin
        ld b, CONFIG_KERNEL_MAX_OPENED_DEVICES
_zos_vfs_clean_close:
        ld a, b
        dec a
        ld h, b
        call zos_vfs_close
        ld b, h
        djnz _zos_vfs_clean_close
        ; Fall-throught

        ; Populate the stdin and stdout in the opened dev table.
        ; Call their respective open function again.
        ; Parameters:
        ;       None
        ; Returns:
        ;       None
        ; Alters:
        ;       HL
        PUBLIC zos_vfs_restore_std
zos_vfs_restore_std:
        ; Populate the stdout and stdin entries
        ld hl, (_dev_default_stdout)
        ld (_dev_table), hl
        ld hl, (_dev_default_stdin)
        ld (_dev_table + 2), hl
        ret

        ; Routine to set the default stdout of the system
        ; This is where the logs will go by defaults
        ; Parameters:
        ;       HL - Pointer to the driver
        ; Returns:
        ;       A - ERR_SUCCESS on success, error code else
        ; Alters:
        ;       A
        PUBLIC zos_vfs_set_stdout
zos_vfs_set_stdout:
        ; Test for a NULL pointer
        ld a, h
        or l
        jp z, _zos_vfs_invalid_parameter
        ld (_dev_default_stdout), hl
        ; If entry STANDARD_OUTPUT is null, fill it now
        push hl
        ld hl, (_dev_table + STANDARD_OUTPUT)
        ld a, h
        or l
        pop hl
        jr nz, _zos_vfs_set_stdout_no_set
        ld (_dev_table + STANDARD_OUTPUT), hl
_zos_vfs_set_stdout_no_set:
        call zos_log_stdout_ready
        xor a   ; Optimization for A = ERR_SUCCESS
        ret        

        ; Routine to set the default stdin of the system
        ; Parameters:
        ;       HL - Pointer to the driver
        ; Returns:
        ;       A - ERR_SUCCESS on success, error code else
        ; Alters:
        ;       A
        PUBLIC zos_vfs_set_stdin
zos_vfs_set_stdin:
        ; Test for a NULL pointer
        ld a, h
        or l
        jp z, _zos_vfs_invalid_parameter
        ld (_dev_default_stdin), hl
        xor a   ; Optimization for A = ERR_SUCCESS
        ret

_zos_vfs_invalid_parameter_popdehl:
        pop de
_zos_vfs_invalid_parameter_pophl:
        pop hl
_zos_vfs_invalid_parameter:
        ld a, ERR_INVALID_PARAMETER
        ret


        ; Routines used to interact with the drivers

        ; Open the given file or driver
        ; Drivers name shall not exceed 4 characters and must be preceeded by VFS_DRIVER_INDICATOR (#)
        ; (5 characters in total)
        ; Names not starting with # will be considered as files.
        ; Parameters:
        ;       BC - Name: driver or file
        ;       H - Flags, can be O_RDWR, O_RDONLY, O_WRONLY, O_NONBLOCK, O_CREAT, O_APPEND, etc...
        ;           It is possible to OR them.
        ; Returns:
        ;       A - Number for the newly opened dev on success, negated error value else.
        ; Alters:
        ;       A
        PUBLIC zos_vfs_open
zos_vfs_open:
        push hl
        push de
        push bc
        ; Check if BC is NULL
        ld a, b
        or c
        jp z, _zos_vfs_open_ret_invalid
        ; Cehck flags consistency
        call zos_vfs_check_opn_flags
        or a
        jp nz, _zos_vfs_open_ret_err
        ; Check that we have room in the dev table. HL will be altered, save H (flags in D)
        ld d, h
        call zos_vfs_find_entry
        ; A is 0 on success
        or a
        jp nz, _zos_vfs_open_ret_err
        ; Check if the given path points to a driver or a file
        ld a, (bc)
        ; Check if the string is empty (A == 0)
        or a
        jp z, _zos_vfs_open_ret_invalid
        cp VFS_DRIVER_INDICATOR
        jp z, _zos_vfs_open_drv
        ; Open a file here
        ; Check if the first char is '/', in that case, it's an absolute path to the current disk
        cp '/'
        inc bc  ; doesn't update flags, so, safe
        jp z, _zos_vfs_open_absolute_disk
        ; Check if the driver letter was passed. It's the case when the second and third
        ; chars are ':/'
        ld e, a         ; Store the disk letter in E
        ld a, (bc)
        cp ':'
        jp nz, _zos_vfs_open_file
        inc bc
        ld a, (bc)
        cp '/'
        jp nz, _zos_vfs_open_file_dec
        ; The path given is an absolute system path, including disk letter
        ; Make BC point to the first directory name and not ('/')
        inc bc
_zos_vfs_open_absolute:
        ; BC - Address of the path, which starts after X:/
        ; DE - Flags | Disk letter
        ; HL - Address of the empty dev.
        ; Before calling the disk API, we have to prepare the arguments:
        ; BC - Flags | Disk letter
        ; HL - Absolute path to the file (without X:/)
        ; Exchange BC with DE, then HL with DE
        ; ex bc, de
        ld a, d
        ld d, b
        ld b, a
        ld a, e
        ld e, c
        ld c, a
        ; DE now contains the full path, BC contains Flags | Disk letter
        ex de, hl
        ; It doesn't save any register
        push de
        call zos_disk_open_file
        pop de
        or a
        jp nz, _zos_vfs_open_ret_err
        ; It was a success, store the newly obtained descriptor (HL) in the free entry (DE)
        ex de, hl
        jp _zos_vfs_open_save_de_and_exit
        ;=================================;
        ; Open a file relative to the current path
        ; For example:
        ;       myfile.txt
_zos_vfs_open_file_dec:
        dec bc
_zos_vfs_open_file:
        dec bc
        ; In both cases (above), at this point, BC is the address of the filename.
        ; D - Contains the flags
        ; HL - Address of the empty dev.
        ; TODO: Normalize the path by getting the realpath. Currently, we are going to ignore
        ; the fact that paths can contain .., . or multiple /, the path MUST be correct.
        ; In practice, we should check that the last char is not / 
        ; Here we have to retrieve the current disk, from _vfs_current_dir
        push hl
        ld a, (_vfs_current_dir)
        ld e, a
        ; Load the filename in HL
        ld hl, _vfs_current_dir + 3 ; skip the X:/
        ; Get the length of the current dir. We will concatenate to it the new filename.
        push de
        ld d, b
        ld e, c
        ld bc, CONFIG_KERNEL_PATH_MAX
        ; Concatenate DE into HL, with a max size of BC (including \0)
        call strncat
        ; Here, store DE (flags + disk letter) in BC as DE contains the former NULL byte address of HL
        pop bc
        ; Check if A is 0 (success)
        or a
        ; Load the error code in case
        ld a, ERR_PATH_TOO_LONG
        jp nz, _zos_vfs_open_ret_pophl
        ; We can now pass the path to the disk API
        ; B: Flags
        ; C: Disk letter
        ; HL: Absolute path to the file (without X:/)
        ; DE: Former address of HL's NULL-byte
        ; It doesn't save any registers, save them here
        push de
        call zos_disk_open_file
        pop de
        ; Returns status in A (0 if success) and dev descriptor in HL,
        ; we have to save it in case of success.
        ; In any case, restore HL's former NULL-byte
        ex de, hl
        ld (hl), 0
        ; Check zos_disk_open_file return value
        or a
        jp nz, _zos_vfs_open_ret_pophl
        ; Return was a success, we can save the dev descriptor from DE (the free entry address is on the stack)
        pop hl
_zos_vfs_open_save_de_and_exit:
        ld (hl), e
        inc hl
        ld (hl), d
        ; We have to return the index of the newly opened dev, we can calculate it
        ; from HL. We need to perform A = (HL - 1 - _dev_table) / 2.
        ld bc, _dev_table
        scf
        sbc hl, bc
        ; HL is now an 8-bit value, because we have at most 128 entries
        ld a, l
        ; Divide by 2 with rra as carry is 0 (because of sbc)
        rra
        jp _zos_vfs_open_ret
        ; Open a file with an absolute path of the current disk 
        ; For example: /mydir/myfile.txt
        ; BC is pointing at the char of index 1 already (after /)
_zos_vfs_open_absolute_disk:
        ; Open the file as an absolute path, but load the current disk first
        ; Disk letter must be put in E. We cannot use HL here.
        ld a, (_vfs_current_dir)
        ld e, a
        jp _zos_vfs_open_absolute
        
        ; Open a driver, the length of the driver name must be 4
        ; HL - The address of the empty dev entry
        ; BC - Driver name (including #)
        ; D - Flags
_zos_vfs_open_drv:
        inc bc
        push hl
        ; The length will be check by zos_driver_find_by_name, no need to do it here
        ; Put the driver name in HL instead of BC. Flags in B.
        ld h, b
        ld l, c
        ld b, d
        call zos_driver_find_by_name
        ; Check that it was a success
        or a
        jp nz, _zos_vfs_open_ret_pophl
        ; Success, DE contains the driver address, HL contains the name and top of stack contains
        ; the address of the empty dev entry.
        ; Before saving the driver as opened, we have to execute its "open" routine, which MUST succeed!
        ; Parameters:
        ;       BC - name
        ;       H - flags
        ; After this, we will still need DE (driver address).
        push de
        ; Prepare the name, exchange B and H
        ld a, b
        push af ; Save the flags
        ld b, h
        ; ld c, l // C hasn't been modified
        GET_DRIVER_OPEN()
        ; Set the opened dev number in D
        ld a, (_vfs_work_buffer)
        ld d, a
        ; Retrieve the opening flags (A) from the stack
        pop af
        CALL_HL()
        pop de
        ; Check the return value
        or a
        jp nz, _zos_vfs_open_ret_pophl
        ; Success! We can now save the driver inside the empty spot.
        pop hl
        jp _zos_vfs_open_save_de_and_exit
_zos_vfs_open_ret_pophl:
        pop hl
_zos_vfs_open_ret_err:
        ; Error value here, negate it before returning
        neg
_zos_vfs_open_ret:
        pop bc
        pop de
        ; All "syscall" accessible functions, we must pop hl before returning
        pop hl
        ret
_zos_vfs_open_ret_invalid:
        ld a, ERR_INVALID_NAME
        jr _zos_vfs_open_ret_err


        ; Read the given dev number
        ; Parameters:
        ;       H  - Number of the dev to write to
        ;       DE - Buffer to store the bytes read from the dev, the buffer must NOT cross page boundary
        ;       BC - Size of the buffer passed, maximum size is a page size
        ; Returns:
        ;       A  - 0 on success, error value else
        ;       BC - Number of bytes filled in DE.
        ; Alters:
        ;       A, BC
        PUBLIC zos_vfs_read
zos_vfs_read:
        push hl
        push de
        call zof_vfs_get_entry
        pop de
        or a
        jp nz, _zos_vfs_pop_ret
        ; Check if the buffer and the size are valid, in other words, check that the
        ; size is less or equal to a page size and BC+size doesn't cross page boundary 
        call zos_check_buffer_size
        or a
        jp nz, _zos_vfs_pop_ret
        ; Check if the opened dev is a file or a driver
        call zos_disk_is_opnfile
        or a
        jr z, _zos_vfs_read_isfile
        ; We have a driver here, we will call its `read` function directly with the right
        ; parameters.
        ; Note: All drivers' `read` function take a 32-bit offset as a parameter on the
        ;       stack. For non-block drivers (non-filesystem), this parameter
        ;       doesn't make sense. It will always be 0 and must be popped by the driver
        ; First thing to do it retreive the drivers' read function, to do this,
        ; we need both DE and HL
        push de
        ex de, hl 
        ; Retrieve driver (DE) read function address, in HL.
        GET_DRIVER_READ()
        pop de
        ; HL now contains read address
        ; We have to save DE as it must not be altered,
        ; at the same time, we also have to put a 32-bit offset (= 0)
        ; Use the work buffer to do this, it can then be used freely
        ; by the drivers. That buffer is used as a "dynamic" memory that
        ; is considered as active during a whole syscall.
        ; Which means that after a syscall, `read` for example, it can
        ; be re-used by any other syscall. It's not permanent, it's a
        ; temporary buffer.
        ; Encode jp driver_read_function inside the work buffer
        ld a, 0xc3      ; jp instruction
        ld (_vfs_work_buffer), a
        ld (_vfs_work_buffer + 1), hl
        push de
        ld hl, zos_vfs_read_driver_return
        push hl ; Return address
        ld hl, 0
        push hl
        push hl ; 32-bit offset parameter (0)
        ; Jump to that read function
        jp _vfs_work_buffer
zos_vfs_read_driver_return:
        ; Restore DE and HL before returning
        pop de
        pop hl
        ret
_zos_vfs_read_isfile:
        push de
        call zos_disk_read
        pop de
        pop hl
        ret


        ; Write to the given dev number.
        ; Parameters:
        ;       H  - Number of the dev to write to
        ;       DE - Buffer to write to the dev. the buffer must NOT cross page boundary.
        ;       BC - Size of the buffer passed. Maximum size is a page size.
        ; Returns:
        ;       A  - 0 on success, error value else
        ;       BC - Number of bytes remaining to be written. 0 means everything has been written.
        ; Alters:
        ;       A, HL, BC
        PUBLIC zos_vfs_write
zos_vfs_write:
        push hl
        ; We use the same flow as the one for the read function
        push de
        call zof_vfs_get_entry
        pop de
        or a
        jp nz, _zos_vfs_pop_ret
        call zos_check_buffer_size
        or a
        jp nz, _zos_vfs_pop_ret
        ; Check if the opened dev is a file or a driver
        call zos_disk_is_opnfile
        or a
        jr z, _zos_vfs_write_isfile
        ; We have a driver here, we will call its `write` function directly with the right
        ; parameters.
        push de
        ex de, hl 
        ; Retrieve driver (DE) `write` function address, in HL.
        GET_DRIVER_WRITE()
        pop de
        ; HL now contains `write` function's address.
        ; Encode jp driver_write_function inside the work buffer
        ld a, 0xc3      ; jp instruction
        ld (_vfs_work_buffer), a
        ld (_vfs_work_buffer + 1), hl
        push de
        ld hl, zos_vfs_write_driver_return
        push hl ; Return address
        ld hl, 0
        push hl
        push hl ; 32-bit offset parameter (0)
        ; Jump to that read function
        jp _vfs_work_buffer
zos_vfs_write_driver_return:
        ; Restore DE and HL before returning
        pop de
        pop hl
        ret
_zos_vfs_write_isfile:
        push de
        call zos_disk_write
        pop de
        pop hl
        ret

        ; Close the given dev number
        ; This should be done as soon as a dev is not required anymore, else, this could
        ; prevent any other `open` to succeed.
        ; Note: when a program terminates, all its opened devs are closed and STDIN/STDOUT
        ; are reset.
        ; Parameters:
        ;       H - Number of the dev to close
        ; Returns:
        ;       A - ERR_SUCCESS on success, error code else
        PUBLIC zos_vfs_close
zos_vfs_close:
        push hl
        ; Save the dev number, we will pass it to the close function
        ; in case it is a driver
        ld a, h
        ld (_vfs_work_buffer), a
        push de
        call zof_vfs_get_entry
        pop de
        or a
        jp nz, _zos_vfs_pop_ret
        ; Check if the opened dev is a file or a driver
        call zos_disk_is_opnfile
        or a
        jr z, _zos_vfs_close_isfile
        ; We have a driver here, we will call its `close` function directly.
        push de
        push bc
        ex de, hl 
        ; Retrieve driver (DE) close function address, in HL.
        GET_DRIVER_CLOSE()
        ; HL now contains the address of driver's close function. Call it
        ; with the dev number as a parameter
        ld a, (_vfs_work_buffer) 
        CALL_HL()
        ; Restore DE and HL before returning
        pop bc
        pop de
        pop hl
        ret
_zos_vfs_close_isfile:
        push de
        call zos_disk_close
_zos_vfs_popdehl_ret:
        pop de
        pop hl
        ret

        ; Return the stats of an opened file.
        ; The returned structure is defined in `vfs_h.asm` file.
        ; Each field of the structure is name file_*_t.
        ; Parameters:
        ;       H - Dev number
        ;       DE - File info stucture, this memory pointed must be big
        ;            enough to store the file information
        ; Returns:
        ;       A - 0 on success, error else
        PUBLIC zos_vfs_dstat
zos_vfs_dstat:
        push hl
        ; Check DE parameter
        ld a, d
        or e
        jp z, _zos_vfs_invalid_parameter
        push de
        call zof_vfs_get_entry
        pop de
        or a
        jr nz, _zos_vfs_dstat_pop_ret
        ; HL contains the opened dev address, DE the structure address
        ; Now, `stat` operation is only valid for files, not drivers, so we
        ; have to check if the opened address is a file or not, fortunately,
        ; `disk` component can do that.
        call zos_disk_is_opnfile
        or a
        jp nz, _zos_vfs_dstat_pop_ret
        ; Call the `disk` component for getting the file stats if success
        push bc
        push de
        call zos_disk_stat
        pop de
        pop bc
_zos_vfs_dstat_pop_ret:
_zos_vfs_pop_ret:
        pop hl
        ret


        ; Performs an IO request to an opened driver.
        ; The behavior of this syscall is driver-dependent.
        ; Parameters:
        ;       H - Dev number, must refer to an opened driver (not a file)
        ;       C - Command number. This is driver-dependent, check the
        ;           driver documentation for more info.
        ;       DE - 16-bit parameter. This is also driver dependent.
        ;            This can be used as a 16-bit value or as an address.
        ;            Similarly to the buffers in `read` and `write` routines,
        ;            If this is an address, it must not cross a page boundary.
        ; Returns:
        ;       A - ERR_SUCCESS on success, error code else
        PUBLIC zos_vfs_ioctl
zos_vfs_ioctl:
        push hl
        push bc
        ld b, h
        ; Get the entry address in HL
        push de
        call zof_vfs_get_entry
        ; Return directly if an error occured
        or a
        jp nz, _zos_vfs_ioctl_pop_ret
        ; If the entry is a opened file/directory, return an error too
        call zos_disk_is_opnfile
        or a
        ld a, ERR_INVALID_PARAMETER
        jp z, _zos_vfs_ioctl_pop_ret
        ; HL points to a driver, get the IOCTL routine address
        ex de, hl
        GET_DRIVER_IOCTL()
        ; HL points to the IOCTL routine, prepare the parameters.
        ; C has not been modified, B conains the dev number
        pop de
        push de
        CALL_HL()
_zos_vfs_ioctl_pop_ret:
        pop de
        pop bc
        pop hl
        ret

        ; Move the cursor of an opened file or an opened driver.
        ; In case of a driver, the implementation is driver-dependent.
        ; In case of a file, the cursor never moves further than
        ; the file size. If the given whence is SEEK_SET, and the
        ; given offset is bigger than the file, the cursor will
        ; be set to the end of the file.
        ; Similarly, if the whence is SEEK_END and the given offset
        ; is positive, the cursor won't move further than the end of
        ; the file.
        ; Parameters:
        ;       H - Dev number, must refer to an opened driver (not a file)
        ;       BCDE - 32-bit offset, signed if whence is SEEK_CUR/SEEK_END.
        ;              Unsigned if SEEK_SET.
        ;       A - Whence. Can be SEEK_CUR, SEEK_END, SEEK_SET.
        ; Returns:
        ;       A - ERR_SUCCESS on success, error code else.
        ;       BCDE - Unsigned 32-bit offset. Resulting file offset.
        PUBLIC zos_vfs_seek
zos_vfs_seek:
        ; check if the whence is valid
        cp SEEK_END + 1 
        jp nc, _zos_vfs_invalid_parameter
        ; Save the whence in memory as we will need it later
        ld (_vfs_work_buffer + 2), a
        push hl
        push de
        call zof_vfs_get_entry
        or a
        jp nz, _zos_vfs_popdehl_ret
        ; Check if the opened dev is a file or a driver
        call zos_disk_is_opnfile
        or a
        jr z, _zos_vfs_seek_isfile
        ; HL points to a driver, get its `seek` function.
        ex de, hl 
        ; Retrieve driver (DE) read function address, in HL.
        GET_DRIVER_SEEK()
        ; HL now contains address of `seek` routine.
        ; In theory, we could use CALL_HL() directly.
        ; In practice, this would mean we would have to drop
        ; one of the parameter, which we should avoid.
        ld a, 0xc3      ; jp instruction
        ld (_vfs_work_buffer), a
        ld (_vfs_work_buffer + 1), hl
        ; Put the whence in A
        ld a, (_vfs_work_buffer + 2)
        pop de
        ; We have to get the original HL from the stack too as it contains
        ; the "dev" number.
        pop hl
        ; Save it back as it must not be modified
        push hl
        call _vfs_work_buffer
        pop hl
        ret
_zos_vfs_seek_isfile:
        ; DE is not preserved accross the call, no need to save it
        ; again after popping it.
        pop de
        call zos_disk_seek
        pop hl
        ret


        PUBLIC zos_vfs_mkdir
zos_vfs_mkdir:

        PUBLIC zos_vfs_getdir
zos_vfs_getdir:

        PUBLIC zos_vfs_chdir
zos_vfs_chdir:

        PUBLIC zos_vfs_rddir
zos_vfs_rddir:

        PUBLIC zos_vfs_rm
zos_vfs_rm:

        ; Mount a new disk, given a driver, a letter and a file system.
        ; The letter assigned to the disk must not be in use.
        ; Parameters:
        ;       H - Dev number. It must be an opened driver, not a file.
        ;       D - ASCII letter to assign to the disk (upper or lower)
        ;       E - File system, taken from `vfs_h.asm`
        ; Returns:
        ;       A - ERR_SUCCESS on succes, error code else
        PUBLIC zos_vfs_mount
zos_vfs_mount:
        push hl
        push de
        call zof_vfs_get_entry
        pop de
        or a
        jp nz, _zos_vfs_pop_ret
        ; Check if the entry is a file/directory or a driver
        call zos_disk_is_opnfile
        or a
        ld a, ERR_INVALID_PARAMETER
        jp z, _zos_vfs_pop_ret
        ; The dev is a driver, we can try to mount it directly
        push de
        ld a, d ; Letter to mount it on in A register
        call zos_disks_mount
        pop de
        pop hl
        ret

        ; Duplicate on dev number to another dev number.
        ; This can be handy to override the standard input or output
        ; Note: New dev number MUST be empty/closed before calling this
        ; function, else, an error will be returned
        ; Parameters:
        ;       H - Old dev number
        ;       E - New dev number
        ; Returns:
        ;       A - ERR_SUCCESS on success, error code else
        PUBLIC zos_vfs_dup
zos_vfs_dup:
        push hl
        push de
        ; Check that the "old" dev is a valid entry
        call zof_vfs_get_entry
        pop de
        or a
        jp nz, _zos_vfs_pop_ret
        ; Check that the "new" dev entry is empty
        ld a, e
        cp CONFIG_KERNEL_MAX_OPENED_DEVICES
        jp nc, _zos_vfs_invalid_parameter_pophl
        push de
        push hl
        ; We need to multiple A by two as each entry is 2 bytes long
        rlca
        ld hl, _dev_table
        ADD_HL_A()
        ld a, (hl)
        inc hl
        or (hl)
        ; Before checking A, pop the "old" dev's content in DE
        ; After this, two elements are on the stack: former DE value,
        ; and former HL value.
        pop de
        ; If A is not zero, then the entry is not free
        jp nz, _zos_vfs_invalid_parameter_popdehl
        ; It's free! Copy the "old" dev value to it.
        ld (hl), d
        dec hl
        ld (hl), e
        pop de
        pop hl
        ; Both "new" and "old" devs can be used now
        ; Return success, A is already 0.
        ret


        ; Returns the stats of a file.
        ; Same as the function above, but with a file path instead of an opened dev.
        ; Parameters:
        ;       BC - Path to the file
        ;       DE - File info stucture, this memory pointed must be big
        ;            enough to store the file information (>= STAT_STRUCT_SIZE)
        ; Returns:
        ;       A - 0 on success, error else
        ; Alters:
        ;       TBD
        PUBLIC zos_vfs_stat
zos_vfs_stat:
        ld a, ERR_NOT_IMPLEMENTED
        ret

        ;======================================================================;
        ;================= P R I V A T E   R O U T I N E S ====================;
        ;======================================================================;

        ; Check the consistency of the passed flags for open routine.
        ; For example, it is inconsistent to pass both 
        ; O_RDWR and O_WRONLY flag, or both O_TRUNC and O_APPEND
        ; Parameters:
        ;       H - Flags
        ; Returns:
        ;       A - ERR_SUCCESS on success or error code else
zos_vfs_check_opn_flags:
        ld a, h
        ; Check that we don't have both O_RDWR and O_WRONLY
        and O_WRONLY | O_RDWR
        cp O_WRONLY | O_RDWR
        jr z, _zos_vfs_invalid_flags
        ; Check that O_TRUNC is not given with O_APPEND
        ld a, h
        and O_TRUNC | O_APPEND
        cp O_TRUNC | O_APPEND
        jr z, _zos_vfs_invalid_flags
        xor a
        ret
_zos_vfs_invalid_flags:
        ld a, ERR_BAD_MODE
        ret

        ; Check that a buffer address and its size are valid.
        ; They are valid if the size is less or equal to an MMU page size, and if
        ; the buffer doesn't cross the page-boundary
        ; Parameters:
        ;       DE - Buffer address
        ;       BC - Buffer size
        ; Returns:
        ;       A - ERR_SUCCESS is buffer and size valid, ERR_INVALID_PARAMETER else
        ; Alters:
        ;       A
zos_check_buffer_size:
        push hl
        xor a
        ld hl, MMU_VIRT_PAGES_SIZE
        sbc hl, bc
        jr z, zos_check_buffer_size_invalidparam
        push de
        ; BC is less than a page size, get the page number of DE
        MMU_GET_PAGE_INDEX_FROM_VIRT_ADDRESS()
        ; Page index of DE in A, calculate page index for the last buffer address:
        ; DE+BC-1
        ld h, d
        ld l, e
        adc hl, bc
        dec hl
        ld d, a ; Save the page index in D
        ; Echange HL and DE as MMU_GET_PAGE_INDEX_FROM_VIRT_ADDRESS needs the address in DE
        ex de, hl
        MMU_GET_PAGE_INDEX_FROM_VIRT_ADDRESS()
        ex de, hl
        ; Compare D and A, they must be equal
        sub d
        pop de
        jr nz, zos_check_buffer_size_invalidparam
        ;A is already 0, we can return
        pop hl
        ret
zos_check_buffer_size_invalidparam:
        pop hl
        ld a, ERR_INVALID_PARAMETER
        ret

        ; Find an empty entry in the _dev_table
        ; Parameters:
        ;       None
        ; Returns:
        ;       A - ERR_SUCCESS on success, error code else
        ;       HL - Address of the empty entry
        ; Alters:
        ;       A
zos_vfs_find_entry:
        push bc
        ld hl, _dev_table
        ld b, CONFIG_KERNEL_MAX_OPENED_DEVICES
        ld c, 0 ; Index of the entry found
_zos_vfs_find_entry_loop:
        ld a, (hl)
        inc hl
        or (hl)
        inc hl
        jp z, _zos_vfs_find_entry_found
        inc c
        djnz _zos_vfs_find_entry_loop
        ; Not found
        ld a, ERR_CANNOT_REGISTER_MORE
        pop bc
        ret
_zos_vfs_find_entry_found:
        ; Save the index in the work buffer
        ld a, c
        ld (_vfs_work_buffer), a
        ; Return ERR_SUCCESS
        xor a
        ; Make HL point to the empty entry
        dec hl
        dec hl
        pop bc
        ret

        ; Get the entry of index H
        ; Parameters:
        ;       H - Index of the opened dev to retrieve
        ; Returns:
        ;       HL - Opened dev address
        ;       A - ERR_SUCCESS if success, error else
        ; Alters:
        ;       A, DE, HL
zof_vfs_get_entry:
        ld a, h
        cp CONFIG_KERNEL_MAX_OPENED_DEVICES
        jp nc, _zos_vfs_invalid_parameter
        ; DE = [HL + 2*A]
        ld hl, _dev_table
        rlca
        ADD_HL_A()
        ld e, (hl)
        inc hl
        ld d, (hl)
        ex de, hl
        ; Success if HL is not 0
        ld a, h
        or l
        jp z, _zos_vfs_invalid_parameter
        xor a
        ret

        ; Normalize the absolute NULL-terminated path given in HL while
        ; copying it to DE. This means that all the ., .., // will be removed
        ; from the path. At most CONFIG_KERNEL_PATH_MAX bytes will be written.
        ; The source path must not contain the disk letter.
        ; For example, HL cannot be:
        ;       C:/mydir/.//myfile.txt
        ; It should be:
        ;       /mydir/.//myfile.txt
        ; In that case, DE will be:
        ;       /mydir/myfile.txt
        ; Parameters:
        ;       HL - Source path
        ;       DE - Destination path
        ; Returns:
        ;       A - ERR_SUCCESS is success, error code else
        ; Alters:
        ;       A, HL
zos_realpath:
        push de
        push bc
        ; C will be our flags
        ; Bit 7: DE path at root
        ; Bit 4: valid char seen
        ; Bit 3: '...' seen
        ; Bit 2: '..' seen
        ; Bit 1: '.' seen
        ; Bit 0: '/' seen
        ; B is the destination path length
        ; FIXME: Maximum path length is 255
        ld c, 0x80
        ld b, 0
_zos_realpath_loop:
        ld a, (hl)
        or a    ; Check if end of string
        jp z, _zos_realpath_end_str
        cp '/'
        jp z, _zos_realpath_slash
        ; Not a slash, clear the flag
        res 0, c
        cp '.'
        jp z, _zos_realpath_dot
        ; Other characters, should be valid (printable)
        ; Check if any '.' or '..' is pending
        bit 1, c
        call nz, _zos_realpath_print_dot
        bit 2, c
        call nz, _zos_realpath_print_double_dot
        ld (de), a
        inc de
        inc hl
        inc b
        ; Clear the . and .. flag, set the valid char one
        ld a, c
        and 0x80
        or 0x10
        ld c, a
        jp _zos_realpath_loop
_zos_realpath_slash:
        inc hl
        ; In most cases, the flags won't be set, so optimize a bit here
        ld a, c
        and 0x07        ; Only the first 3 bits are interesting
        jp z, _zos_realpath_slash_write
        ; Reset the valid char seen flag
        res 4, c 
        ; If we've seen a slash already, skip this part, else, set the slash-flag
        rrca    ; Bit 0 in CY
        jp c, _zos_realpath_loop
        ; Add the 'slash' flag
        set 0, c
        ; If we encountered a single '.', we should NOT modify the output, as
        ; './' means current folder
        res 1, c
        rrca    ; Bit 1 in CY
        jp c, _zos_realpath_loop
        ; We have encountered a '..', if we are at root, error, else, we have to
        ; look for the previous '/'
        bit 7, c
        jp nz, _zos_realpath_error_path
        res 2, c
        ; Look for the previous '/' in the destination
        ; For exmaple, if HL is /mydir/../
        ; Destination would be /mydir/, and DE pointing after the last slash
        ; We have to look for the one before the last one.
        dec de
        dec de
        dec b
        push bc
        ld c, b
        ld b, 0
        ex de, hl
        ld a, '/'
        cpdr
        ld a, c
        pop bc
        ld b, a
        ex de, hl
        ; Make DE point back at the next empty char
        inc de
        inc de
        inc b
        ; If the resulted size is 0 (A), then we have to set the flag
        or a
        jp nz, _zos_realpath_loop
        set 7, c
        jp _zos_realpath_loop
_zos_realpath_slash_write:
        ; Add the 'slash' flag, and remove the other flags
        ld c, 1
        ; If B is 0, then we are still at the beginning of the path, still
        ; at the root, do not clean that flag
        ld a, b
        or a
        jp nz, _zos_realpath_slash_write_noset
        set 7, c
_zos_realpath_slash_write_noset:
        ; Add a slash to DE
        ld a, '/'
        ld (de), a
        inc de
        inc b
        ; Go back to the loop
        jp _zos_realpath_loop
_zos_realpath_dot:
        ; We've just came accross a dot.
        ; If we've already seen a triple dot, then this dot is part of a file name
        bit 3, c
        jr nz, _zos_realpath_valid_dot
        ; If we have seen regulart characters before, the dot is valid
        bit 4, c
        jr nz, _zos_realpath_valid_dot
        ; If we've seen a .. before, then, this dot makes the file name '...'
        ; this is not a special sequence, so we have to write these to DE.
        bit 2, c
        jr nz, _zos_realpath_tripledot
        ; Update the flags and continue  the loop. Do not write anything to the
        ; destination (yet). If we saw a dot before, the flags become:
        ; xxxxx_x01x => xxxxx_x10x
        ; If we haven't, it becomes:
        ; xxxxx_x00x => xxxxx_x01x
        ; Thus, simply perform c += 2
        inc c
        inc c
        inc hl
        jp _zos_realpath_loop
_zos_realpath_tripledot:
        ld (de), a
        inc de
        ld (de), a
        inc de
        ld (de), a
        inc de
        inc b
        inc b
        inc b
        ; Set the valid flag and clean the double dot one
        res 2, c
        set 3, c
_zos_realpath_valid_dot:
        ld (de), a
        inc de
        inc b
        inc hl
        jp _zos_realpath_loop
_zos_realpath_end_str:
        xor a
        ld (de), a
        pop bc
        pop de
        ret
_zos_realpath_error_path:
        ; When .. is passed at the root 
        ld a, 1
        pop bc
        pop de
        ret
_zos_realpath_print_double_dot:
        call _zos_realpath_print_dot
_zos_realpath_print_dot:
        ex de, hl
        ld (hl), '.'
        ex de, hl
        inc de
        inc b
        ret

        SECTION KERNEL_BSS
        ; Each of these entries points to either a driver (when opened a device) or an abstract
        ; structure returned by a disk (when opening a file)
_dev_default_stdout: DEFS 2
_dev_default_stdin: DEFS 2
_dev_table: DEFS CONFIG_KERNEL_MAX_OPENED_DEVICES * 2
_vfs_current_dir_backup: DEFS CONFIG_KERNEL_PATH_MAX + 1   ; Used before executing a program
_vfs_current_dir: DEFS CONFIG_KERNEL_PATH_MAX + 1          ; Restored once a program exits
        ; Work buffer usable by any (virtual) file system. It shall only be used by one
        ; FS implementation at a time, thus, it shall be used as a temporary buffer in
        ; the routines.
        PUBLIC _vfs_work_buffer
_vfs_work_buffer: DEFS VFS_WORK_BUFFER_SIZE