; -*- fundamental -*- (asm-mode sucks)
; $Id$
; ****************************************************************************
;
;  ldlinux.asm
;
;  A program to boot Linux kernels off an MS-DOS formatted floppy disk.	 This
;  functionality is good to have for installation floppies, where it may
;  be hard to find a functional Linux system to run LILO off.
;
;  This program allows manipulation of the disk to take place entirely
;  from MS-LOSS, and can be especially useful in conjunction with the
;  umsdos filesystem.
;
;  This file is loaded in stages; first the boot sector at offset 7C00h,
;  then the first sector (cluster, really, but we can only assume 1 sector)
;  of LDLINUX.SYS at 7E00h and finally the remainder of LDLINUX.SYS at 8000h.
;
;   Copyright (C) 1994-1998  H. Peter Anvin
;
;  This program is free software; you can redistribute it and/or modify
;  it under the terms of the GNU General Public License as published by
;  the Free Software Foundation, Inc., 675 Mass Ave, Cambridge MA 02139,
;  USA; either version 2 of the License, or (at your option) any later
;  version; incorporated herein by reference.
; 
; ****************************************************************************

;
; Some semi-configurable constants... change on your own risk
;
max_cmd_len	equ 255			; Must be odd; 255 is the kernel limit
retry_count	equ 6			; How patient are we with the disk?

;
; Should be updated with every release to avoid bootsector/SYS file mismatch
;
%define	version_str	VERSION		; Must be 4 characters long!
%define date		DATE_STR	; Defined from the Makefile
%define	year		'1998'
;
; Debgging stuff
;
; %define debug 1			; Uncomment to enable debugging
;
; ID for SYSLINUX (reported to kernel)
;
syslinux_id	equ 031h		; SYSLINUX (3) version 1.x (1)
;
; Segments used by Linux
;
real_mode_seg	equ 9000h
		struc real_mode_seg_t
		resb 20h-($-$$)		; org 20h
kern_cmd_magic	resw 1			; Magic # for command line
kern_cmd_offset resw 1			; Offset for kernel command line
		resb 497-($-$$)		; org 497d
bs_setupsecs	resb 1			; Sectors for setup code (0 -> 4)
bs_rootflags	resw 1			; Root readonly flag
bs_syssize	resw 1
bs_swapdev	resw 1			; Swap device (obsolete)
bs_ramsize	resw 1			; Ramdisk flags, formerly ramdisk size
bs_vidmode	resw 1			; Video mode
bs_rootdev	resw 1			; Root device
bs_bootsign	resw 1			; Boot sector signature (0AA55h)
su_jump		resb 1			; 0EBh
su_jump2	resb 1
su_header	resd 1			; New setup code: header
su_version	resw 1			; See linux/arch/i386/boot/setup.S
su_switch	resw 1
su_setupseg	resw 1
su_startsys	resw 1
su_kver		resw 1			; Kernel version pointer
su_loader	resb 1			; Loader ID
su_loadflags	resb 1			; Load high flag
su_movesize	resw 1
su_code32start	resd 1			; Start of code loaded high
su_ramdiskat	resd 1			; Start of initial ramdisk
su_ramdisklen	equ $			; Length of initial ramdisk
su_ramdisklen1	resw 1
su_ramdisklen2	resw 1
su_bsklugeoffs	resw 1
su_bsklugeseg	resw 1
su_heapend	resw 1
		resb (8000h-12)-($-$$)	; Were bootsect.S puts it...
linux_stack	equ $
linux_fdctab	equ $
		resb 8000h-($-$$)
cmd_line_here	equ $			; Should be out of the way
		endstruc

setup_seg	equ 9020h
		struc setup_seg_t
		org 0h			; as 9020:0000, not 9000:0200
setup_entry	equ $
		endstruc

;
; Magic number of su_header field
;
HEADER_ID       equ 'HdrS'		; HdrS (in littleendian hex)
;
; Flags for the su_loadflags field
;
LOAD_HIGH	equ 01h			; Large kernel, load high
CAN_USE_HEAP    equ 80h                 ; Boot loader reports heap size
;
; The following structure is used for "virtual kernels"; i.e. LILO-style
; option labels.  The options we permit here are `kernel' and `append
; Since there is no room in the bottom 64K for all of these, we
; stick them at 8000:0000 and copy them down before we need them.
;
; Note: this structure can be added to, but it must 
;
%define vk_power	7		; log2(max number of vkernels)
%define	max_vk		(1 << vk_power)	; Maximum number of vkernels
%define vk_shift	(16-vk_power)


		struc vkernel
vk_vname:	resb 11			; Virtual name **MUST BE FIRST!**
vk_rname:	resb 11			; Real name
vk_appendlen:	resw 1
vk_type:	resb 1			; Type of entry
		alignb 4
vk_append:	resb max_cmd_len+1	; Command line
		alignb 4
vk_size:	equ $			; Should == 1 << vk_shift
		endstruc

%if vk_size*max_vk > 65536
%error Too many vkernels defined
%endif

%define vk_t_kernel	0		; File is a kernel image
%define vk_t_bootsec	1		; File is a boot sector image
%define vk_t_run	2		; File is a COMboot .com image

;
; Segment assignments in the bottom 640K
; 0000h - main code/data segment (and BIOS segment)
; 9000h - real_mode_seg
;
vk_seg          equ 8000h		; This is where we stick'em
xfer_buf_seg	equ 7000h		; Bounce buffer for I/O to high mem
fat_seg		equ 1000h		; 128K area for FAT (2x64K)

;
; For our convenience: define macros for jump-over-unconditinal jumps
;
%macro	jmpz	1
	jnz %%skip
	jmp %1
%%skip:
%endmacro

%macro	jmpnz	1
	jz %%skip
	jmp %1
%%skip:
%endmacro

%macro	jmpe	1
	jne %%skip
	jmp %1
%%skip:
%endmacro

%macro	jmpne	1
	je %%skip
	jmp %1
%%skip:
%endmacro

%macro	jmpc	1
	jnc %%skip
	jmp %1
%%skip:
%endmacro

%macro	jmpnc	1
	jc %%skip
	jmp %1
%%skip:
%endmacro

%macro	jmpb	1
	jnb %%skip
	jmp %1
%%skip:
%endmacro

%macro	jmpnb	1
	jb %%skip
	jmp %1
%%skip:
%endmacro

;
; Macros similar to res[bwd], but which works in the code segment (after
; section .text)
;
%macro	zb	1
	times %1 db 0
%endmacro

%macro	zw	1
	times %1 dw 0
%endmacro

%macro	zd	1
	times %1 dd 0
%endmacro

; ---------------------------------------------------------------------------
;   BEGIN THE BIOS/CODE/DATA SEGMENT
; ---------------------------------------------------------------------------
		absolute 4*1Eh		; In the interrupt table
fdctab		equ $
fdctab1		resw 1
fdctab2		resw 1

%ifdef debug
		org 0100h
..start:	
;
; Hook for debugger stuff.  This gets automatically removed when
; generating the real thing.
;
; Initialize the registers for debugger operation
;
		cli
		mov ax,cs
		mov ds,ax
		mov es,ax
		mov ss,ax
		mov sp,StackBuf
		sti
		cld
;
; Load the actual boot sector so we can copy the data block
;
		xor ax,ax		; Reset floppy
		xor dx,dx
		int 13h
		mov cx,6		; Retry count...
debug_tryloop:	push cx
		mov bx,trackbuf
		mov cx,0001h
		xor dx,dx
		mov ax,0201h
		int 13h
		pop cx
		jnc debug_okay
		loop debug_tryloop
		int 3			; Halt! (Breakpoint)
debug_okay:	mov si,trackbuf+0bh
		mov di,bsBytesPerSec
		mov cx,33h
		rep movsb
;
; Save bogus "BIOS floppy block" info to the stack in case we hit kaboom
;
		push si
		push si
		push si			; Writing to the trackbuf is harmless
;
; Copy the BIOS data area
;
                push ds
                xor ax,ax
                mov ds,ax
                mov si,0400h
                mov di,si
                mov cx,0100h
                rep movsw
                pop ds
;
;
; A NOP where we can breakpoint, then jump into the code *after*
; the segment register initialization section
;
		nop
		jmp debugentrypt
%endif

                absolute 0484h
BIOS_vidrows    resb 1                    ; Number of screen rows

;
; Memory below this point is reserved for the BIOS and the MBR
;
 		absolute 1000h
trackbuf	equ $			; Track buffer goes here
trackbufsize	equ 16384		; Safe size of track buffer
;		trackbuf ends at 5000h

                absolute 6000h          ; Here we keep our BSS stuff
StackBuf	equ $			; Start the stack here (grow down - 4K)
VKernelBuf:	resb vk_size		; "Current" vkernel
		alignb 4
AppendBuf       resb max_cmd_len+1	; append=
KbdMap		resb 256		; Keyboard map
FKeyName	resb 10*16		; File names for F-key help
NumBuf		resb 16			; Buffer to load number
NumBufEnd	equ NumBuf+15		; Pointer to last byte in NumBuf
		alignb 4
InitRDat	resd 1			; Load address (linear) for initrd
HiLoadAddr      resd 1			; Address pointer for high load loop
RootDir		equ $			; Location of root directory
RootDir1	resw 1
RootDir2	resw 1
DataArea	equ $			; Location of data area
DataArea1	resw 1
DataArea2	resw 1
FBytes		equ $			; Used by open/getc
FBytes1		resw 1
FBytes2		resw 1
RootDirSize	resw 1			; Root dir size in sectors
DirScanCtr	resw 1			; Used while searching directory
DirBlocksLeft	resw 1			; Ditto
EndofDirSec	resw 1			; = trackbuf+bsBytesPerSec-31
RunLinClust	resw 1			; Cluster # for LDLINUX.SYS
ClustSize	resw 1			; Bytes/cluster
SecPerClust	resw 1			; Same as bsSecPerClust, but a word
NextCluster	resw 1			; Pointer to "nextcluster" routine
BufSafe		resw 1			; Clusters we can load into trackbuf
BufSafeSec	resw 1			; = how many sectors?
BufSafeBytes	resw 1			; = how many bytes?
EndOfGetCBuf	resw 1			; = getcbuf+BufSafeBytes
HighMemSize	resw 1			; High memory (K)
KernelClust	resw 1			; Kernel size in clusters
KernelK		resw 1			; Kernel size in kilobytes
InitRDClust	resw 1			; Ramdisk size in clusters
ClustPerMoby	resw 1			; Clusters per 64K
FClust		resw 1			; Number of clusters in open/getc file
FNextClust	resw 1			; Pointer to next cluster in d:o
FPtr		resw 1			; Pointer to next char in buffer
CmdOptPtr       resw 1			; Pointer to first option on cmd line
KernelCNameLen  resw 1			; Length of unmangled kernel name
InitRDCNameLen  resw 1			; Length of unmangled initrd name
NextCharJump    resw 1			; Routine to interpret next print char
SetupSecs	resw 1			; Number of setup sectors
TextAttrBX      equ $
TextAttribute   resb 1			; Text attribute for message file
TextPage        resb 1			; Active display page
CursorDX        equ $
CursorCol       resb 1			; Cursor column for message file
CursorRow       resb 1			; Cursor row for message file
ScreenSize      equ $
VidCols         resb 1			; Columns on screen-1
VidRows         resb 1			; Rows on screen-1
RetryCount      resb 1			; Used for disk access retries
KbdFlags	resb 1			; Check for keyboard escapes
LoadFlags	resb 1			; Loadflags from kernel
KernelType	resb 1			; Type of "kernel" we're loading
MNameBuf        resb 11            	; Generic mangled file name buffer
KernelName      resb 11		        ; Mangled name for kernel
InitRD          resb 11                 ; initrd= mangled name
KernelCName     resb 13                 ; Unmangled kernel name
InitRDCName     resb 13            	; Unmangled initrd name

		section .text
                org 7C00h
bootsec		equ $
		jmp short start		; 2 bytes
		nop			; 1 byte
;
; "Superblock" follows -- it's in the boot sector, so it's already
; loaded and ready for us
;
bsOemName	db 'SYSLINUX'		; The SYS command sets this, so...
bsBytesPerSec	zw 1
bsSecPerClust	zb 1
bsResSectors	zw 1
bsFATs		zb 1
bsRootDirEnts	zw 1
bsSectors	zw 1
bsMedia		zb 1
bsFATsecs	zw 1
bsSecPerTrack	zw 1
bsHeads		zw 1
bsHiddenSecs	equ $
bsHidden1	zw 1
bsHidden2	zw 1
bsHugeSectors	equ $
bsHugeSec1	zw 1
bsHugeSec2	zw 1
bsDriveNumber	zb 1
bsReserved1	zb 1
bsBootSignature zb 1			; 29h if the following fields exist
bsVolumeID	zd 1
bsVolumeLabel	zb 11
bsFileSysType	zb 8			; Must be FAT12 for this version
;
; Note we don't check the constraints above now; we did that at install
; time (we hope!)
;

floppy_table	equ $			; No sense in wasting memory, overwrite start

start:
		cli			; No interrupts yet, please
		jmp 0:start1		; Some stupid BIOSes jumps to 07C0:0000 not 0000:7C00
start1:
;
; Set up ES and SS, and the stack
;
		xor ax,ax
		mov ss,ax
		mov sp,StackBuf		; Just below BSS
;
; DS:SI may contain a partition table entry.  Preserve it for us.
;
		mov dh,[si]		; "Active flag" (sanity check)
		mov bp,[si+8]		; LSW of linear offset
		mov bx,[si+10]		; MSW of linear offset

; Now sautee the BIOS floppy info block to that it will support decent-
; size transfers; the floppy block is 11 bytes and is stored in the
; INT 1Eh vector (brilliant waste of resources, eh?)
;
; Of course, if BIOSes had been properly programmed, we wouldn't have
; had to waste precious boot sector space with this code.
;
; This code no longer fits.  Hope that noone really needs it anymore.
;
%ifdef SUPPORT_BROKEN_BIOSES
		lds si,[ss:fdctab]	; DS:SI -> original
		push ds			; Save on stack in case
		push si			; we have to bail
		push bx
		mov cx,6		; 12 bytes
		mov di,floppy_table
		push di
		cld
		rep movsw		; Faster to move words
		pop di
		mov ds,ax		; Now we can point DS to here, too
		mov cl,[bsSecPerTrack]  ; Patch the sector count
		mov [di+4],cl
		mov [fdctab+2],ax	; Segment 0
		mov [fdctab],di		; offset floppy_block
%else
		mov ds,ax
%endif
;
; Ready to enable interrupts, captain
;
		sti
;
; Reset floppy system
;
		xor dx,dx
		int 13h			; AH = 00h already
;
; The drive number and possibly partition information was passed to us
; by the BIOS or previous boot loader (MBR).  Current "best practice" is to
; trust that rather than what the superblock contains.
;
; Would it be better to zero out bsHidden if we don't have a partition table?
;
		push dx
		mov [bsDriveNumber],dl
		test dl,80h		; If floppy disk (00-7F), assume no
		jz not_harddisk		; partition table
		test dh,7Fh		; Sanity check: "active flag" should
		jnz no_partition	; be 00 or 80
		mov [bsHidden1],bp
		mov [bsHidden2],bx
no_partition:
;
; Get disk drive parameters (don't trust the superblock.)  Don't do this for
; floppy drives -- INT 13:08 on floppy drives will return info about what the
; *drive* supports, not about the *media*...
;
		pop dx			; Restore DL = drive #
		mov ah,08h
		int 13h
		jc no_driveparm
		and ah,ah
		jnz no_driveparm
		inc dh			; Contains # of heads - 1
		mov [bsHeads],dh
		and cx,3fh
		mov [bsSecPerTrack],cx
no_driveparm:
not_harddisk:
;
; Now we have to do some arithmetric to figure out where things are located.
; If Microsoft had had brains they would already have done this for us,
; and stored it in the superblock at format time, but here we go,
; wasting precious boot sector space again...
;
debugentrypt:
		xor si,si		; Some BIOSes destroy ES for INT 13:08
		mov es,si		; so we clear it this late

		mov al,[bsFATs]		; Number of FATs (AH == 0)
		jc kaboom		; If the floppy init failed
		mul word [bsFATsecs]	; Get the size of the FAT area
		add ax,[bsHidden1]	; Add hidden sectors
		adc dx,[bsHidden2]
		add ax,[bsResSectors]	; And reserved sectors
		adc dx,si		; SI == 0

		mov [RootDir1],ax	; Location of root directory
		mov [RootDir2],dx
		mov [DataArea1],ax
		mov [DataArea2],dx
		push ax
		push dx

		mov ax,32		; Size of a directory entry
		mul word [bsRootDirEnts]
		mov bx,[bsBytesPerSec]
		add ax,bx		; Round up, not down
		dec ax
		div bx			; Now we have the size of the root dir
		mov [RootDirSize],ax
		mov [DirScanCtr],ax
		add bx,trackbuf-31
		mov [EndofDirSec],bx	; End of a single directory sector

		add [DataArea1],ax
		adc word [DataArea2],si	; SI == 0

		pop dx			; Reload root directory starting point
		pop ax
;
; Now the fun begins.  We have to search the root directory for
; LDLINUX.SYS and load the first sector, so we have a little more
; space to have fun with.  Then we can go chasing through the FAT.
; Joy!!
;
sd_nextsec:	push ax
		push dx
		mov bx,trackbuf
		push bx
		call getonesec
		pop si
sd_nextentry:	cmp byte [si],0		; Directory high water mark
		je kaboom
		mov di,ldlinux_sys
		mov cx,11
		push si
		repe cmpsb
		pop si
		je found_it
		add si,byte 32		; Distance to next
		cmp si,[EndofDirSec]
		jb sd_nextentry
		pop dx
		pop ax
		add ax,byte 1
		adc dx,byte 0
		dec word [DirScanCtr]
		jnz sd_nextsec
;
; kaboom: write a message and bail out.
;
kaboom:
		mov sp,StackBuf-2*3 	; Reset stack
		pop si			; BIOS floppy block address
		cli
		pop word [si]		; Restore location
		pop word [si+2]
		sti
;		mov si,bailmsg
;		call writestr		; Returns with AL = 0
;		cbw			; AH <- 0
;		int 16h			; Wait for keypress
;		int 19h			; And try once more to boot...
		int 18h			; Bail.  Hope this does something useful.
norge:		jmp short norge		; If int 19h returned; this is the end

;
; found_it: now we compute the location of the first sector, then
;	    load it and JUMP (since we're almost out of space)
;
found_it:	; Note: we actually leave two words on the stack here
		; (who cares?)
		mov al,[bsSecPerClust]
		xor ah,ah
		mov bp,ax		; Load an entire cluster
		mov bx,[si+26]		; First cluster
		mov [RunLinClust],bx	; Save for later use
		dec bx			; First cluster is cluster 2
		dec bx
		mul bx
		add ax,[DataArea1]
		adc dx,[DataArea2]
		mov bx,ldlinux_magic
		push bx
		call getlinsec
		mov si,bs_magic
		pop di
		mov cx,magic_len
		repe cmpsb		; Make sure that the bootsector
		jne kaboom		; matches LDLINUX.SYS
		jmp ldlinux_ent
;
; writestr: write a null-terminated string to the console
;
writestr:
wstr_1:         lodsb
		and al,al
                jz return
		mov ah,0Eh		; Write to screen as TTY
		mov bx,0007h		; White on black, current page
		int 10h
		jmp short wstr_1

;
; disk_error: decrement the retry count and bail if zero
;
disk_error:	dec si			; SI holds the disk retry counter
		jz kaboom
		xchg ax,bx		; Shorter than MOV
		pop bx			; <I>
		pop cx			; <H>
		pop dx			; <G>
		jmp short disk_try_again
;
; getonesec: like getlinsec, but pre-sets the count to 1
;
getonesec:
		mov bp,1
		; Fall through to getlinsec

;
; getlinsec: load a sequence of BP floppy sector given by the linear sector
;	     number in DX:AX into the buffer at ES:BX.	We try to optimize
;	     by loading up to a whole track at a time, but the user
;	     is responsible for not crossing a 64K boundary.
;	     (Yes, BP is weird for a count, but it was available...)
;
;	     On return, BX points to the first byte after the transferred
;	     block.
;
;	     When compiling with the STUPID option, this is replaced by a
;	     routine which loads one sector at a time.
;
getlinsec:
		mov si,[bsSecPerTrack]
		div si			; Convert linear to sector/track
		mov cx,dx		; Save sector
		xor dx,dx		; 32-bit track number
		div word [bsHeads]	; Convert track to head/cyl
		;
		; Now we have AX = cyl, DX = head, CX = sector (0-based),
		; BP = sectors to transfer, SI = bsSecPerTrack,
		; ES:BX = data target
		;
gls_nextchunk:	push si			; <A> bsSecPerTrack
		push bp			; <B> Sectors to transfer
%ifdef STUPID
		mov bp,1
		nop			; Minimize size of patch
		nop
		nop
		nop
		nop
%else
		sub si,cx		; Sectors left on track
		cmp bp,si
		jna gls_lastchunk
		mov bp,si		; No more than a trackful, please!
gls_lastchunk:	
%endif
		push ax			; <C> Cylinder #
		push dx			; <D> Head #
		push bp			; <E> Number of sectors we're transferring

		push cx			; <F> Sector #
		mov cl,6		; Because IBM was STOOPID
		shl ah,cl		; and thought 8 bits were enough
					; then thought 10 bits were enough...
		pop cx			; <F> Sector #
		push cx
		inc cx			; Sector numbers are 1-based
		or cl,ah
		mov ch,al
		mov dh,dl
		mov dl,[bsDriveNumber]
		xchg ax,bp		; Sector to transfer count
					; (xchg shorter than mov)
		mov ah,02h		; Read it!
;
; Do the disk transfer... save the registers in case we fail :(
;
		mov si,retry_count	; # of times to retry a disk access
disk_try_again: push dx			; <G>
		push cx			; <H>
		push bx			; <I>
		push ax			; <J>
		push si			; <K>
		int 13h
		pop si			; <K>
		pop bx			; <J>
		jc disk_error
;
; Disk access successful
;
		pop bx			; <I> Buffer location
		pop ax			; <H> No longer needed
		pop ax			; <G> No longer needed
		pop cx			; <F> Sector #
		pop di			; <E> Sector transferred count
		mov ax,di		; Reduce sector left count
		mul word [bsBytesPerSec] ; Figure out how much to advance ptr
		add bx,ax		; Update buffer location
		pop dx			; <D> Head #
		pop ax			; <C> Cyl #
		pop bp			; <B> Sectors left to transfer
		pop si			; <A> Number of sectors/track
		sub bp,di		; Reduce with # of sectors just read
		jz return		; Done!
		add cx,di
		cmp cx,si
		jb gls_nextchunk
		inc dx			; Next track on cyl
		cmp dx,[bsHeads]	; Was this the last one?
		jb gls_nonewcyl
		inc ax			; If so, new cylinder
		xor dx,dx		; First head on new cylinder
gls_nonewcyl:	sub cx,si		; First sector on new track
		jmp short gls_nextchunk
return:		ret

; bailmsg		db 'Error!', 0Dh, 0Ah, 0

bs_checkpt	equ $			; Must be <= 1E3h

		zb 1E3h-($-$$)
bs_magic	equ $			; The following 32 bytes should
					; match ldlinux_magic
ldlinux_sys	db 'LDLINUX SYS'	; Looks like this in the root dir
		db ' '
bs_version	db version_str
		db ' '
bs_date		db date
magic_len	equ $-bs_magic

bootsignature	dw 0AA55h

;
; ===========================================================================
;  End of boot sector
; ===========================================================================
;  Start of LDLINUX.SYS
; ===========================================================================
;
; This "magic number" works well with the "type" command... the 0 we treat
; as end of string, but is ignored by "type".
;
ldlinux_magic	db 'LDLINUX'
missing_dot	db ' '
		db 'SYS ', version_str, ' ', date
magic_eof	db 0, 
crlf		db 0Dh, 0Ah, 0, 01Ah

		align 4
ldlinux_ent:
;
; Tell the user we got this far
;
		mov si,crlf
		call writestr
		mov byte [missing_dot],'.'
		mov si,ldlinux_magic
		call writestr
;
; Remember, the boot sector loaded only the first cluster of LDLINUX.SYS.
; We can really only rely on a single sector having been loaded.  Hence
; we should load the FAT into RAM and start chasing pointers...
;
		mov dx,1			; 64K
		xor ax,ax
		div word [bsBytesPerSec]	; sectors/64K
		mov si,ax

		push es
		mov bx,fat_seg			; Load into fat_seg:0000
		mov es,bx
		
		mov ax,[bsHidden1]		; Hidden sectors
		mov dx,[bsHidden2]
		add ax,[bsResSectors]		; plus reserved sectors = FAT
		adc dx,byte 0
		mov cx,[bsFATsecs]		; Sectors/FAT
fat_load_loop:	
		mov bp,cx
		cmp bp,si
		jna fat_load
		mov bp,si			; A full 64K moby
fat_load:	
		xor bx,bx			; Offset 0 in the current ES
		call getlinsecsr
		sub cx,bp
		jz fat_load_done		; Last moby?
		add ax,bp			; Advance sector count
		adc dx,byte 0
		mov bx,es			; Next 64K moby
		add bx,1000h
		mov es,bx
		jmp short fat_load_loop
fat_load_done:
		pop es
;
; Fine, now we have the FAT in memory.	How big is a cluster, really?
; Also figure out how many clusters will fit in an 8K buffer, and how
; many sectors and bytes that is
;
		mov di,[bsBytesPerSec]		; Used a lot below

		mov al,[bsSecPerClust]		; We do this in the boot
		xor ah,ah			; sector, too, but there
		mov [SecPerClust],ax		; wasn't space to save it
		mov si,ax			; Also used a lot...
		mul di
		mov [ClustSize],ax		; Bytes/cluster
		mov bx,ax
		mov ax,trackbufsize
		xor dx,dx
		div bx
		mov [BufSafe],ax		; # of cluster in trackbuf
		mul word [SecPerClust]
		mov [BufSafeSec],ax
		mul di
		mov [BufSafeBytes],ax
		add ax,getcbuf			; getcbuf is same size as
		mov [EndOfGetCBuf],ax		; trackbuf, for simplicity
;
; FAT12 or FAT16?  This computation is fscking ridiculous...
;
		xor dx,dx
		xor cx,cx
		mov ax,[bsSectors]
		and ax,ax
		jnz have_secs
		mov ax,[bsHugeSectors]
		mov dx,[bsHugeSectors+2]
have_secs:	sub ax,[bsResSectors]
		sbb dx,byte 0
		mov cl,[bsFATs]
sec_fat_loop:	sub ax,[bsFATsecs]
		sbb dx,byte 0
		loop sec_fat_loop
		push ax
		push dx
		mov ax,[bsRootDirEnts]
		mov bx,32			; Smaller than shift since we
		mul bx				; need the doubleword product
		add ax,di
		adc dx,byte 0
		sub ax,byte 1
		sbb dx,byte 0
		div di
		mov bx,ax
		pop dx
		pop ax
		sub ax,bx
		sbb dx,byte 0
		div si
		cmp ax,4086			; Right value?
		mov ax,nextcluster_fat16
		ja have_fat_type
have_fat12:	mov ax,nextcluster_fat12
have_fat_type:	mov word [NextCluster],ax

;
; Now we read the rest of LDLINUX.SYS.	Don't bother loading the first
; cluster again, though.
;
load_rest:
		mov cx,[ClustSize]
		mov bx,ldlinux_magic
		add bx,cx
		mov si,[RunLinClust]
		call [NextCluster]
		xor dx,dx
		mov ax,ldlinux_len-1		; To be on the safe side
		add ax,cx
		div cx				; the number of clusters
		dec ax				; We've already read one
		jz all_read_jmp
		mov cx,ax
		call getfssec
;
; All loaded up
;
all_read_jmp:
		jmp all_read
;
; -----------------------------------------------------------------------------
; Subroutines that have to be in the first sector
; -----------------------------------------------------------------------------
;
; getfssec: Get multiple clusters from a file, given the starting cluster.
;
;	This routine makes sure the subtransfers do not cross a 64K boundary,
;	and will correct the situation if it does, UNLESS *sectors* cross
;	64K boundaries.
;
;	ES:BX	-> Buffer
;	SI	-> Starting cluster number (2-based)
;	CX	-> Cluster count (0FFFFh = until end of file)
;
						; 386 check
getfssec:
getfragment:	xor bp,bp			; Fragment sector count
		mov ax,si			; Get sector address
		dec ax				; Convert to 0-based
		dec ax
		mul word [SecPerClust]
		add ax,[DataArea1]
		adc dx,[DataArea2]
getseccnt:					; See if we can read > 1 clust
		add bp,[SecPerClust]
		dec cx				; Reduce clusters left to find
		mov di,si			; Predict next cluster
		inc di
		call [NextCluster]
		jc gfs_eof			; At EOF?
		jcxz endfragment		; Or was it the last we wanted?
		cmp si,di			; Is file continuous?
		jz getseccnt			; Yes, we can get
endfragment:	clc				; Not at EOF
gfs_eof:	pushf				; Remember EOF or not
		push si
		push cx
gfs_getchunk:
		push ax
		push dx
		mov ax,es			; Check for 64K boundaries.
		mov cl,4
		shl ax,cl
		add ax,bx
		xor dx,dx
		neg ax
		jnz gfs_partseg
		inc dx				; Full 64K segment
gfs_partseg:
		div word [bsBytesPerSec]	; How many sectors fit?
		mov si,bp
		sub si,ax			; Compute remaining sectors
		jbe gfs_lastchunk
		mov bp,ax
		pop dx
		pop ax
		call getlinsecsr
		add ax,bp
		adc dx,byte 0
		mov bp,si			; Remaining sector count
		jmp short gfs_getchunk
gfs_lastchunk:	pop dx
		pop ax		
		call getlinsec
		pop cx
		pop si
		popf
		jcxz gfs_return			; If we hit the count limit
		jnc getfragment			; If we didn't hit EOF
gfs_return:	ret

;
; getlinsecsr: save registers, call getlinsec, restore registers
;
getlinsecsr:	push ax
		push dx
		push cx
		push bp
		push si
		call getlinsec
		pop si
		pop bp
		pop cx
		pop dx
		pop ax
		ret

;
; nextcluster: Advance a cluster pointer in SI to the next cluster
;	       pointed at in the FAT tables (note: FAT12 assumed)
;	       Sets CF on return if end of file.
;
;	       The variable NextCluster gets set to the appropriate
;	       value here.
;
nextcluster_fat12:
		push ax
		push ds
		mov ax,fat_seg
		mov ds,ax
		mov ax,si			; Multiply by 3/2
		shr ax,1
		pushf				; CF now set if odd
		add si,ax
		mov si,[si]
		popf
		jnc nc_even
		shr si,1			; Needed for odd only
		shr si,1
		shr si,1
		shr si,1
nc_even:
		and si,0FFFh
		cmp si,0FF0h			; Clears CF if at end of file
		cmc				; But we want it SET...
		pop ds
		pop ax
nc_return:	ret

;
; FAT16 decoding routine.  Note that a 16-bit FAT can be up to 128K,
; so we have to decide if we're in the "low" or the "high" 64K-segment...
;
nextcluster_fat16:
		push ax
		push ds
		mov ax,fat_seg
		shl si,1
		jnc .seg0
		mov ax,fat_seg+1000h
.seg0:		mov ds,ax
		mov si,[si]
		cmp si,0FFF0h
		cmc
		pop ds
		pop ax
		ret
;
; Debug routine
;
%ifdef debug
safedumpregs:
		cmp word [Debug_Magic],0D00Dh
		jnz nc_return
		jmp dumpregs
%endif

rl_checkpt	equ $				; Must be <= 400h

; ----------------------------------------------------------------------------
;  End of code and data that have to be in the first sector
; ----------------------------------------------------------------------------

all_read:
;
; Let the user (and programmer!) know we got this far.  This used to be
; in Sector 1, but makes a lot more sense here.
;
		mov si,copyright_str
		call writestr
;
; Check that no moron is trying to boot Linux on a 286 or so.  According
; to Intel, the way to check is to see if the high 4 bits of the FLAGS
; register are either all stuck at 1 (8086/8088) or all stuck at 0
; (286 in real mode), if not it is a 386 or higher.  They didn't
; say how to check for a 186/188, so I *hope* it falls out as a 8086
; or 286 in this test.
;
; Also, provide an escape route in case it doesn't work.
;
check_escapes:
		mov ah,02h			; Check keyboard flags
		int 16h
		mov [KbdFlags],al		; Save for boot prompt check
		test al,04h			; Ctrl->skip 386 check
		jnz skip_checks
test_8086:
		pushf				; Get flags
		pop ax
		and ax,0FFFh			; Clear top 4 bits
		push ax				; Load into FLAGS
		popf
		pushf				; And load back
		pop ax
		and ax,0F000h			; Get top 4 bits
		cmp ax,0F000h			; If set -> 8086/8088
		je not_386
test_286:
		pushf				; Get flags
		pop ax
		or ax,0F000h			; Set top 4 bits
		push ax
		popf
		pushf
		pop ax
		and ax,0F000h			; Get top 4 bits
		jnz is_386			; If not clear -> 386
not_386:
		mov si,err_not386
		call writestr
		jmp kaboom
is_386:
		; Now we know it's a 386 or higher
;
; Now check that there is at least 608K of low (DOS) memory
; (608K = 9800h segments)
;
		int 12h
		cmp ax,608
		jae enough_ram
		mov si,err_noram
		call writestr
		jmp kaboom
enough_ram:
skip_checks:

;
; Initialization that does not need to go into the any of the pre-load
; areas
;
		call adjust_screen
;
; Now we're all set to start with our *real* business.	First load the
; configuration file (if any) and parse it.
;
; In previous versions I avoided using 32-bit registers because of a
; rumour some BIOSes clobbered the upper half of 32-bit registers at
; random.  I figure, though, that if there are any of those still left
; they probably won't be trying to install Linux on them...
;
; The code is still ripe with 16-bitisms, though.  Not worth the hassle
; to take'm out.  In fact, we may want to put them back if we're going
; to boot ELKS at some point.
;
		mov si,linuxauto_cmd		; Default command: "linux auto"
		mov di,default_cmd
                mov cx,linuxauto_len
		rep movsb

		mov di,KbdMap			; Default keymap 1:1
		xor al,al
		mov cx,256
mkkeymap:	stosb
		inc al
		loop mkkeymap

;
; Load configuration file
;
		mov di,syslinux_cfg
		call open
		jz near no_config_file
parse_config:
		call getkeyword
                jc near end_config_file		; Config file loaded
		cmp ax,'de'			; DEfault
		je pc_default
		cmp ax,'ap'			; APpend
		je pc_append
		cmp ax,'ti'			; TImeout
		je near pc_timeout
		cmp ax,'pr'			; PRompt
		je near pc_prompt
		cmp ax,'fo'			; FOnt
		je near pc_font
		cmp ax,'kb'			; KBd
		je near pc_kbd
		cmp ax,'di'			; DIsplay
		je near pc_display
		cmp ax,'la'			; LAbel
		je near pc_label
		cmp ax,'ke'			; KErnel
		je pc_kernel
		cmp ax,'bo'			; BOotsec
		je pc_bootsec
		cmp ax,'ru'			; RUn
		je pc_run
                cmp ax,'im'                     ; IMplicit
                je near pc_implicit
		cmp al,'f'			; F-key
		jne parse_config
		jmp pc_fkey

pc_default:	mov di,default_cmd		; "default" command
		call getline
		mov si,auto_cmd			; add "auto"+null
                mov cx,auto_len
		rep movsb
		jmp short parse_config

pc_append:      cmp word [VKernelCtr],byte 0	; "append" command
		ja pc_append_vk
                mov di,AppendBuf
		call getline
                sub di,AppendBuf
pc_app1:        mov [AppendLen],di
                jmp short parse_config
pc_append_vk:	mov di,VKernelBuf+vk_append	; "append" command (vkernel)
		call getline
		sub di,VKernelBuf+vk_append
                cmp di,byte 2
                jne pc_app2
                cmp byte [VKernelBuf+vk_append],'-'
                jne pc_app2
                mov di,0                        ; If "append -" -> null string
pc_app2:        mov [VKernelBuf+vk_appendlen],di
		jmp short parse_config_2	

pc_bootsec:	mov al,vk_t_bootsec		; "bootsec" command
		jmp short pc_vkernel

pc_run:		mov al,vk_t_run			; "run" command
		jmp short pc_vkernel

pc_kernel:	mov al,vk_t_kernel		; "kernel" command
pc_vkernel:	cmp word [VKernelCtr],byte 0
		je near parse_config		; ("label" section only)
		mov [VKernelBuf+vk_type],al
		mov di,trackbuf
		push di
		call getline
		pop si
		mov di,VKernelBuf+vk_rname
		call mangle_name
		jmp short parse_config_2

pc_timeout:	call getint			; "timeout" command
		jc parse_config_2
		mov ax,0D215h			; There are approx 1.D215h
		mul bx				; clock ticks per 1/10 s
		add bx,dx
		mov [KbdTimeOut],bx
		jmp short parse_config_2

pc_display:	call pc_getfile			; "display" command
		jz parse_config_2		; File not found?
		call get_msg_file		; Load and display file
parse_config_2: jmp parse_config

pc_prompt:	call getint			; "prompt" command
		jc parse_config_2
		mov [ForcePrompt],bx
		jmp short parse_config_2

pc_implicit:    call getint                     ; "implicit" command
                jc parse_config_2
                mov [AllowImplicit],bx
                jmp short parse_config_2

pc_fkey:	sub ah,'1'
		jnb pc_fkey1
		mov ah,9			; F10
pc_fkey1:	xor cx,cx
		mov cl,ah
		push cx
		mov ax,1
		shl ax,cl
		or [FKeyMap], ax		; Mark that we have this loaded
		mov di,trackbuf
		push di
		call getline			; Get filename to display
		pop si
		pop di
		shl di,4			; Multiply number by 16
		add di,FKeyName
		call mangle_name		; Mangle file name
		jmp short parse_config_2

pc_label:	call commit_vk			; Commit any current vkernel
		mov di,trackbuf			; Get virtual filename
		push di
		call getline
		pop si
		mov di,VKernelBuf+vk_vname
		call mangle_name		; Mangle virtual name
		inc word [VKernelCtr]		; One more vkernel
		mov si,VKernelBuf+vk_vname 	; By default, rname == vname
		mov di,VKernelBuf+vk_rname
		mov cx,11
		rep movsb
		; By default, this is a Linux kernel image
		mov byte [VKernelBuf+vk_type],vk_t_kernel
                mov si,AppendBuf         	; Default append==global append
                mov di,VKernelBuf+vk_append
                mov cx,[AppendLen]
                mov [VKernelBuf+vk_appendlen],cx
                rep movsb
		jmp short parse_config_2

pc_font:	call pc_getfile			; "font" command
		jz parse_config_2		; File not found?
		call loadfont			; Load and install font
		jmp short parse_config_3

pc_kbd:		call pc_getfile			; "kbd" command
		jz parse_config_3
		call loadkeys
parse_config_3:	jmp parse_config

;
; pc_getfile:	For command line options that take file argument, this
; 		routine decodes the file argument and runs it through searchdir
;
pc_getfile:	mov di,trackbuf
		push di
		call getline
		pop si
		mov di,MNameBuf
		push di
		call mangle_name
		pop di
		jmp searchdir			; Tailcall

;
; commit_vk: Store the current VKernelBuf into buffer segment
;
commit_vk:
		cmp word [VKernelCtr],byte 0
		je cvk_ret			; No VKernel = return
		cmp word [VKernelCtr],max_vk	; Above limit?
		ja cvk_overflow
		mov di,[VKernelCtr]
		dec di
		shl di,vk_shift
		mov si,VKernelBuf
		mov cx,(vk_size >> 2)
		push es
		push word vk_seg
		pop es
		rep movsd			; Copy to buffer segment
		pop es
cvk_ret:	ret
cvk_overflow:	mov word [VKernelCtr],max_vk	; No more than max_vk, please
		ret

;
; End of configuration file
;
end_config_file:
		call commit_vk			; Commit any current vkernel
no_config_file:
;
; Check whether or not we are supposed to display the boot prompt.
;
check_for_key:
		cmp word [ForcePrompt],byte 0	; Force prompt?
		jnz enter_command
		test byte [KbdFlags],5Bh	; Caps, Scroll, Shift, Alt
		jz near auto_boot		; If neither, default boot

enter_command:
		mov si,boot_prompt
		call writestr

		mov di,command_line
;
; get the very first character -- we can either time
; out, or receive a character press at this time.  Some dorky BIOSes stuff
; a return in the buffer on bootup, so wipe the keyboard buffer first.
;
clear_buffer:	mov ah,1			; Check for pending char
		int 16h
		jz get_char_time
		xor ax,ax			; Get char
		int 16h
		jmp short clear_buffer
get_char_time:	mov cx,[KbdTimeOut]
		and cx,cx
		jz get_char			; Timeout == 0 -> no timeout
		inc cx				; The first loop will happen
						; immediately as we don't
						; know the appropriate DX value
time_loop:	push cx
tick_loop:	push dx
		mov ah,1			; Check for pending keystroke
		int 16h
		jnz get_char_pop
		xor ax,ax
		int 1Ah				; Get time "of day"
		pop ax
		cmp dx,ax			; Has the timer advanced?
		je tick_loop
		pop cx
		loop time_loop			; If so, decrement counter
		jmp command_done		; Timeout!
get_char_pop:	pop eax				; Clear the stack
get_char:	xor ax,ax			; Get char
		int 16h
		and al,al
		jz func_key
		mov bx,KbdMap			; Keyboard map translation
		xlatb
		cmp al,' '			; ASCII?
		jb not_ascii
		ja enter_char
		cmp di,command_line		; Space must not be first
		je get_char
enter_char:	cmp di,max_cmd_len+command_line ; Check there's space
		jnb get_char
		stosb				; Save it
		call writechr			; Echo to screen
		jmp short get_char
not_ascii:	cmp al,0Dh			; Enter
		je command_done
		cmp al,08h			; Backspace
		jne get_char
		cmp di,command_line		; Make sure there is anything
		je get_char			; to erase
		dec di				; Unstore one character
		mov si,wipe_char		; and erase it from the screen
		call writestr
		jmp short get_char
func_key:
		push di
		cmp ah,68			; F10
		ja get_char
		sub ah,59			; F1
		jb get_char
		mov cl,ah
		shr ax,4			; Convert to x16
		mov bx,1
		shl bx,cl
		and bx,[FKeyMap]
		jz get_char			; Undefined F-key
		mov di,ax
		add di,FKeyName
		call searchdir
		jz fk_nofile
		call get_msg_file
		jmp short fk_wrcmd
fk_nofile:
		mov si,crlf
		call writestr
fk_wrcmd:
		mov si,boot_prompt
		call writestr
		pop di				; Command line write pointer
		push di
		mov byte [di],0			; Null-terminate command line
		mov si,command_line
		call writestr			; Write command line so far
		pop di
		jmp short get_char
auto_boot:
		mov si,default_cmd
		mov di,command_line
		mov cx,(max_cmd_len+4) >> 2
		rep movsd
		jmp short load_kernel
command_done:
		mov si,crlf
		call writestr
		cmp di,command_line		; Did we just hit return?
		je auto_boot
		xor al,al			; Store a final null
		stosb

load_kernel:					; Load the kernel now
;
; First we need to mangle the kernel name the way DOS would...
;
		mov si,command_line
                mov di,KernelName
                push si
                push di
		call mangle_name
		pop di
                pop si
;
; Fast-forward to first option (we start over from the beginning, since
; mangle_name doesn't necessarily return a consistent ending state.)
;
clin_non_wsp:   lodsb
                cmp al,' '
                ja clin_non_wsp
clin_is_wsp:    and al,al
                jz clin_opt_ptr
                lodsb
                cmp al,' '
                jbe clin_is_wsp
clin_opt_ptr:   dec si                          ; Point to first nonblank
                mov [CmdOptPtr],si		; Save ptr to first option
;
; Now check if it is a "virtual kernel"
;
		mov cx,[VKernelCtr]
		push ds
		push word vk_seg
		pop ds
		cmp cx,byte 0
		je not_vk
		xor si,si			; Point to first vkernel
vk_check:	pusha
		mov cx,11
		repe cmpsb			; Is this it?
		je vk_found
		popa
		add si,vk_size
		loop vk_check
not_vk:		pop ds
;
; Not a "virtual kernel" - check that's OK and construct the command line
;
		mov byte [KernelType],vk_t_kernel	; Regular kernel
                cmp word [AllowImplicit],byte 0
                je bad_implicit
                push es
                push si
                push di
                mov di,real_mode_seg
                mov es,di
                mov si,AppendBuf
                mov di,cmd_line_here
                mov cx,[AppendLen]
                rep movsb
                mov [CmdLinePtr],di
                pop di
                pop si
                pop es
;
; Find the kernel on disk
;
get_kernel:     mov si,KernelName
                mov di,KernelCName
                call unmangle_name              ; Get human form
                sub di,KernelCName
                mov [KernelCNameLen],di
                mov di,KernelName        	; Search on disk
                call searchdir
                jnz kernel_good
bad_kernel:     mov si,err_notfound		; Complain about missing kernel
		call writestr
                mov si,KernelCName
                call writestr
                mov si,crlf
                jmp abort_load                  ; Ask user for clue
;
; bad_implicit: The user entered a nonvirtual kernel name, with "implicit 0"
;
bad_implicit:   mov si,KernelName		; For the error message
                mov di,KernelCName
                call unmangle_name
                jmp short bad_kernel
;
; vk_found: We *are* using a "virtual kernel"
;
vk_found:	popa
		push di
		mov di,VKernelBuf
		mov cx,vk_size >> 2
		rep movsd
		push es				; Restore old DS
		pop ds
		push es
		push word real_mode_seg
		pop es
		mov di,cmd_line_here
		mov si,VKernelBuf+vk_append
		mov cx,[VKernelBuf+vk_appendlen]
		rep movsb
		mov [CmdLinePtr],di		; Where to add rest of cmd
		pop es
                pop di                          ; DI -> KernelName
		push di	
		mov si,VKernelBuf+vk_rname
		mov cx,11
		rep movsb
		mov al,[VKernelBuf+vk_type]	; Type of kernel to load
		mov [KernelType],al
		pop di
		jmp short get_kernel
;
; kernel_corrupt: Called if the kernel file does not seem healthy
;
kernel_corrupt: mov si,err_notkernel
                jmp abort_load
kernel_good:
;
; This is it!  We have a name (and location on the disk)... let's load
; that sucker!!
;
; A Linux kernel consists of three parts: boot sector, setup code, and
; kernel code.	The boot sector is never executed when using an external
; booting utility, but it contains some status bytes that are necessary.
; The boot sector and setup code together form exactly 5 sectors that
; should be loaded at 9000:0.  The subsequent code should be loaded
; at 1000:0.  For simplicity, we load the whole thing at 0F60:0, and
; copy the latter stuff afterwards.
;
; NOTE: In the previous code I have avoided making any assumptions regarding
; the size of a sector, in case this concept ever gets extended to other
; media like CD-ROM (not that a CD-ROM would be bloody likely to use a FAT
; filesystem, of course).  However, a "sector" when it comes to Linux booting
; stuff means 512 bytes *no matter what*, so here I am using that piece
; of knowledge.
;
; First check that our kernel is at least 64K and less than 8M (if it is
; more than 8M, we need to change the logic for loading it anyway...)
;
load_it:
                cmp dx,80h			; 8 megs
		ja kernel_corrupt
		and dx,dx
		jz kernel_corrupt
kernel_sane:	push ax
		push dx
		push si
		mov si,loading_msg
                call cwritestr
;
; Now start transferring the kernel
;
		push word real_mode_seg
		pop es

		push ax
		push dx
		div word [ClustSize]		; # of clusters total
		and dx,dx			; Round up
		setnz dl
		movzx dx,dl
		add ax,dx
                mov [KernelClust],ax
		pop dx
		pop ax
		add ax,1023
		adc dx,byte 0
		mov bx,1024
		div bx				; Get number of kilobytes
		mov [KernelK],ax
;
; Now, if we transfer these straight, we'll hit 64K boundaries.	 Hence we
; have to see if we're loading more than 64K, and if so, load it step by
; step.
;
		mov dx,1			; 10000h
		xor ax,ax
		div word [ClustSize]
		mov [ClustPerMoby],ax		; Clusters/64K
;
; Start by loading the bootsector/setup code, to see if we need to
; do something funky.  It should fit in the first 32K (loading 64K won't
; work since we might have funny stuff up near the end of memory).
; If we have larger than 32K clusters, yes, we're hosed.
;
		call abort_check		; Check for abort key
		mov cx,[ClustPerMoby]
		shr cx,1			; Half a moby
		sub [KernelClust],cx
		xor bx,bx
                pop si                          ; Cluster pointer on stack
		call getfssec
		jc kernel_corrupt		; Failure in first 32K
                cmp word [es:bs_bootsign],0AA55h
		jne kernel_corrupt		; Boot sec signature missing
		cmp byte [es:su_jump],0EBh	; Jump opcode
		jne kernel_corrupt
;
; Get the BIOS' idea of what the size of high memory is
;
		push si				; Save our cluster pointer!
		mov ah,88h
		int 15h
		cmp ax,14*1024			; Don't trust memory >15M
		jna hms_ok
		mov ax,14*1024
hms_ok:		mov [HighMemSize],ax
;
; Construct the command line (append options have already been copied)
;
		mov word [es:kern_cmd_magic],0A33Fh	; Command line magic no
		mov word [es:kern_cmd_offset],cmd_line_here
		mov di,[CmdLinePtr]
                mov si,boot_image        	; BOOT_IMAGE=
                mov cx,boot_image_len
                rep movsb
                mov si,KernelCName       	; Unmangled kernel name
                mov cx,[KernelCNameLen]
                rep movsb
                mov al,' '                      ; Space
                stosb
                mov si,[CmdOptPtr]              ; Options from user input
		mov cx,(kern_cmd_len+3) >> 2
		rep movsd
;
%ifdef debug
                push ds                         ; DEBUG DEBUG DEBUG
                push es
                pop ds
                mov si,offset cmd_line_here
                call cwritestr
                pop ds
                mov si,offset crlf
                call cwritestr
%endif
;
; Scan through the command line for anything that looks like we might be
; interested in.  The original version of this code automatically assumed
; the first option was BOOT_IMAGE=, but that is no longer certain.
;
		mov si,cmd_line_here
                mov byte [initrd_flag],0
                push es
                pop ds
get_next_opt:   lodsb
		and al,al
		jz near cmdline_end
		cmp al,' '
		jbe get_next_opt
		dec si
                mov eax,[si]
                cmp eax,'vga='
		je is_vga_cmd
                cmp eax,'mem='
		je is_mem_cmd
                push es                         ; Save ES->real_mode_seg
                push cs
                pop es                          ; Set ES <- normal DS
                mov di,initrd_cmd
		mov cx,initrd_cmd_len
		repe cmpsb
                jne not_initrd
		mov di,InitRD
                push si                         ; mangle_dir mangles si
                call mangle_name                ; Mangle ramdisk name
                pop si
		cmp byte [es:InitRD],' '	; Null filename?
                seta byte [es:initrd_flag]	; Set flag if not
not_initrd:     pop es                          ; Restore ES->real_mode_seg
skip_this_opt:  lodsb                           ; Load from command line
                cmp al,' '
                ja skip_this_opt
                dec si
                jmp short get_next_opt
is_vga_cmd:
                add si,byte 4
                mov eax,[si]
                mov bx,-1
                cmp eax, 'norm'                 ; vga=normal
                je vc0
                and eax,0ffffffh		; 3 bytes
                mov bx,-2
                cmp eax, 'ext'                  ; vga=ext
                je vc0
                mov bx,-3
                cmp eax, 'ask'                  ; vga=ask
                je vc0
                call parseint                   ; vga=<number>
		jc skip_this_opt		; Not an integer
vc0:		mov [bs_vidmode],bx		; Set video mode
		jmp short skip_this_opt
is_mem_cmd:
                add si,byte 4
                call parseint
		jc skip_this_opt		; Not an integer
		shr ebx,10			; Convert to kilobytes
                sub ebx,1024                    ; Don't count first meg
		cmp ebx,14*1024			; Only trust < 15M point
                jna memcmd_fair
		mov bx,14*1024
memcmd_fair:    mov [es:HighMemSize],bx
		jmp short skip_this_opt
cmdline_end:
                push cs                         ; Restore standard DS
                pop ds
;
; Now check if we have a large kernel, which needs to be loaded high
;
		cmp dword [es:su_header],HEADER_ID	; New setup code ID
		jne near old_kernel		; Old kernel, load low
		cmp word [es:su_version],0200h	; Setup code version 2.0
		jb near old_kernel		; Old kernel, load low
                cmp word [es:su_version],0201h	; Version 2.01+?
                jb new_kernel                   ; If 2.00, skip this step
                mov word [es:su_heapend],linux_stack	; Set up the heap
                or byte [es:su_loadflags],80h	; Let the kernel know we cared
;
; We definitely have a new-style kernel.  Let the kernel know who we are,
; and that we are clueful
;
new_kernel:
		mov byte [es:su_loader],syslinux_id	; Show some ID
		movzx ax,byte [es:bs_setupsecs]	; Variable # of setup sectors
		mov [SetupSecs],ax
;
; Now see if we have an initial RAMdisk; if so, do requisite computation
;
                test byte [initrd_flag],1
                jz nk_noinitrd
                push es                         ; ES->real_mode_seg
                push ds
                pop es                          ; We need ES==DS
                mov si,InitRD
                mov di,InitRDCName
                call unmangle_name              ; Create human-readable name
                sub di,InitRDCName
                mov [InitRDCNameLen],di
                mov di,InitRD
                call searchdir                  ; Look for it in directory
                pop es
		jz initrd_notthere
		mov [initrd_ptr],si		; Save cluster pointer
		mov [es:su_ramdisklen1],ax	; Ram disk length
		mov [es:su_ramdisklen2],dx
		div word [ClustSize]
		and dx,dx			; Round up
		setnz dl
		movzx dx,dl
		add ax,dx
		mov [InitRDClust],ax		; Ramdisk clusters
		movzx edx,word [HighMemSize]	; End of memory
		add edx,1024			; Add "low" memory
		shl edx,10			; Convert to bytes
		sub edx,[es:su_ramdisklen]	; Subtract size of ramdisk
                xor dx,dx			; Round down to 64K boundary
                mov [InitRDat],edx		; Load address
		call loadinitrd			; Load initial ramdisk
		jmp short initrd_end

initrd_notthere:
                mov si,err_noinitrd
                call writestr
                mov si,InitRDCName
                call writestr
                mov si,crlf
                jmp abort_load

no_high_mem:    mov si,err_nohighmem		; Error routine
                jmp abort_load
;
; About to load the kernel.  This is a modern kernel, so use the boot flags
; we were provided.
;
nk_noinitrd:
initrd_end:
                mov al,[es:su_loadflags]
		mov [LoadFlags],al
;
; Load the kernel.  We always load it at 100000h even if we're supposed to
; load it "low"; for a "low" load we copy it down to low memory right before
; jumping to it.
;
read_kernel:
                mov si,KernelCName		; Print kernel name part of
                call cwritestr                  ; "Loading" message
                mov si,dotdot_msg		; Print dots
                call cwritestr

                mov ax,[HighMemSize]
		cmp ax,[KernelK]
		jb no_high_mem			; Not enough high memory
;
; Move the stuff beyond the setup code to high memory at 100000h
;
		movzx esi,word [SetupSecs]	; Setup sectors
		inc esi				; plus 1 boot sector
                shl esi,9			; Convert to bytes
                mov ecx,108000h			; 108000h = 1M + 32K
                sub ecx,esi			; Adjust pointer to 2nd block
                mov [HiLoadAddr],ecx
		sub ecx,100000h			; Turn into a counter
		shr ecx,2			; Convert to dwords
		add esi,90000h			; Pointer to source
                mov edi,100000h                 ; Copy to address 100000h
                call bcopy			; Transfer to high memory
;
                push word xfer_buf_seg		; Segment 7000h is xfer buffer
                pop es
high_load_loop: 
                mov si,dot_msg			; Progress report
                call cwritestr
                call abort_check
                mov cx,[KernelClust]
		cmp cx,[ClustPerMoby]
		jna high_last_moby
		mov cx,[ClustPerMoby]
high_last_moby:
		sub [KernelClust],cx
		xor bx,bx			; Load at offset 0
                pop si                          ; Restore cluster pointer
                call getfssec
                push si                         ; Save cluster pointer
                pushf                           ; Save EOF
                xor bx,bx
		mov esi,(xfer_buf_seg << 4)
                mov edi,[HiLoadAddr]		; Destination address
                mov ecx,4000h			; Cheating - transfer 64K
                call bcopy			; Transfer to high memory
		mov [HiLoadAddr],edi		; Point to next target area
                popf                            ; Restore EOF
                jc high_load_done               ; If EOF we are done
                cmp word [KernelClust],byte 0	; Are we done?
		jne high_load_loop		; Apparently not
high_load_done:
		pop si				; No longer needed
                mov ax,real_mode_seg		; Set to real mode seg
                mov es,ax

                mov si,dot_msg
                call cwritestr
;
; Abandon hope, ye that enter here!  We do no longer permit aborts.
; Now, if we were supposed to load "low", copy the kernel down to 10000h
;
		test byte [LoadFlags],LOAD_HIGH
		jnz in_proper_place		; If high load, we're done

		movzx ecx,word [KernelK]
		shl ecx,8			; K -> dword
		mov esi,100000h
		mov edi,10000h
		call bcopy
in_proper_place:
;
; If the default root device is set to FLOPPY (0000h), change to
; /dev/fd0 (0200h)
;
		cmp word [es:bs_rootdev],byte 0
		jne root_not_floppy
		mov word [es:bs_rootdev],0200h
root_not_floppy:
;
; Copy the disk table to high memory, then re-initialize the floppy
; controller
;
		mov si,floppy_table
		mov di,linux_fdctab
		mov cx,3			; 12 bytes
		push di
		rep movsd
		pop di
		cli
		mov [fdctab1],di		; Save new floppy tab pos
		mov [fdctab2],es
		sti
		xor ax,ax
		xor dx,dx
		int 13h
;
; Linux wants the floppy motor shut off before starting the kernel,
; at least bootsect.S seems to imply so
;
kill_motor:
		mov dx,03F2h
		xor al,al
		out dx,al
;
; Now we're as close to be done as we can be and still use our normal
; routines, print a CRLF to end the row of dots
;
                call abort_check        ; Last chance!!
		mov si,crlf
		call writestr
;
; If we're debugging, wait for a keypress so we can read any debug messages
;
%ifdef debug
                xor ax,ax
                int 16h
%endif
;
; Set up segment registers and the Linux real-mode stack
;
		mov ax,real_mode_seg
		mov ds,ax
                mov es,ax
		mov fs,ax
		mov gs,ax
		cli
		mov ss,ax
		mov sp,linux_stack
		sti
;
; We're done... now RUN THAT KERNEL!!!!
;
		jmp setup_seg:setup_entry
;
; Load an older kernel.  Older kernels always have 4 setup sectors, can't have
; initrd, and are always loaded low.
;
old_kernel:
                test byte [initrd_flag],1	; Old kernel can't have initrd
                jz load_old_kernel
                mov si,err_oldkernel
                jmp abort_load
load_old_kernel:
		mov word [SetupSecs],4		; Always 4 setup sectors
		mov byte [LoadFlags],0		; Always low
		jmp load_kernel
;
; cwritestr: write a null-terminated string to the console, saving
;            registers on entry (we can't use this in the boot sector,
;            since we haven't verified 386-ness yet)
;
cwritestr:
                pusha
cwstr_1:        lodsb
		and al,al
                jz cwstr_2
		mov ah,0Eh		; Write to screen as TTY
		mov bx,0007h		; White on black, current page
		int 10h
                jmp short cwstr_1
cwstr_2:        popa
                ret

;
; 32-bit bcopy routine for real mode
;
; We enter protected mode, set up a flat 32-bit environment, run rep movsd
; and then exit.  IMPORTANT: This code assumes cs == ss == 0.
;
; This code is probably excessively anal-retentive in its handling of
; segments, but this stuff is painful enough as it is without having to rely
; on everything happening "as it ought to."
;
		align 2
bcopy_gdt_ptr:	dw bcopy_gdt_size-1
		dd bcopy_gdt

		align 4
bcopy_gdt:	dd 0			; Null descriptor
		dd 0
		dd 0000ffffh		; Code segment, use16, readable,
		dd 00009b00h		; present, dpl 0, cover 64K
		dd 0000ffffh		; Data segment, use16, read/write,
		dd 008f9300h		; present, dpl 0, cover all 4G
		dd 0000ffffh		; Data segment, use16, read/write,
		dd 00009300h		; present, dpl 0, cover 64K
bcopy_gdt_size:	equ $-bcopy_gdt

bcopy:
		push eax
		pushf			; Saves, among others, the IF flag
		push gs
		push fs
		push ds
		push es

		cli
		call enable_a20

		o32 lgdt [bcopy_gdt_ptr]
		mov eax,cr0
		or al,1
		mov cr0,eax		; Enter protected mode
		jmp 8:.in_pm

.in_pm:		mov ax,16		; Data segment selector
		mov es,ax
		mov ds,ax

		mov al,24		; "Real-mode-like" data segment
		mov ss,ax
		mov fs,ax
		mov gs,ax	
	
		a32 rep movsd		; Do our business
		
		mov es,ax		; Set to "real-mode-like"
		mov ds,ax
	
		mov eax,cr0
		and al,0feh
		mov cr0,eax		; Disable protected mode
		jmp 0:.in_rm

.in_rm:		xor ax,ax		; Back in real mode
		mov ss,ax
		pop es
		pop ds
		pop fs
		pop gs
		call disable_a20

		popf			; Re-enables interrupts
		pop eax
		ret

;
; Routines to enable and disable (yuck) A20
; These routines are largely cut-and-paste from the Linux setup code
; 
%define	io_delay out 0EDh, ax		; Invalid port (we hope)

enable_a20:
		call empty_8042
		mov al,0D1h		; Command write
		out 064h, al
		call empty_8042
		mov al,0DFh		; A20 on
		out 060h, al
kbc_delay:	call empty_8042
		push cx
		mov cx,14h
.delayloop:	io_delay
		loop .delayloop
		pop cx
		ret

disable_a20:
		call empty_8042
		mov al,0D1h
		out 064h, al		; Command write
		call empty_8042
		mov al,0DDh		; A20 off
		out 060h, al
		jmp short kbc_delay

empty_8042:
		io_delay
		in al, 064h		; Status port
		test al,1
		jz .no_output
		io_delay
		in al, 060h		; Read input
		jmp short empty_8042
.no_output:
		test al,2
		jnz empty_8042
		io_delay
		ret	

;
; Load RAM disk into high memory
;
loadinitrd:
                push es                         ; Save ES on entry
                mov ax,real_mode_seg
                mov es,ax
                mov si,[initrd_ptr]
                mov edi,[InitRDat]		; initrd load address
		mov [es:su_ramdiskat],edi	; Offset for ram disk
		push si
                mov si,InitRDCName		; Write ramdisk name
                call cwritestr
                mov si,dotdot_msg		; Write dots
                call cwritestr
rd_load_loop:	
		mov si,dot_msg			; Progress report
                call cwritestr
		pop si				; Restore cluster pointer
                call abort_check
                mov cx,[InitRDClust]
		cmp cx,[ClustPerMoby]
		jna rd_last_moby
		mov cx,[ClustPerMoby]
rd_last_moby:
		sub [InitRDClust],cx
		xor bx,bx			; Load at offset 0
                push word xfer_buf_seg		; Bounce buffer segment
		pop es
		push cx
		call getfssec
		pop cx
                push si				; Save cluster pointer
		mov esi,(xfer_buf_seg << 4)
		mov edi,[InitRDat]
		mov ecx,4000h			; Copy 64K
		call bcopy			; Does not change flags!!
                jc rd_load_done                 ; EOF?
                add dword [InitRDat],10000h	; Point to next 64K
		cmp word [InitRDClust],byte 0	; Are we done?
		jne rd_load_loop		; Apparently not
rd_load_done:
                pop si                          ; Clean up the stack
                mov si,crlf_msg
		call writestr
                mov si,loading_msg		; Write new "Loading " for
                call writestr                   ; the benefit of the kernel
                pop es                          ; Restore original ES
                ret

;
; abort_check: let the user abort with <ESC> or <Ctrl-C>
;
abort_check:
                pusha
ac1:
		mov ah,1			; Check for pending keystroke
		int 16h
                jz ac_ret                       ; If no pending keystroke
		xor ax,ax			; Load pending keystroke
		int 16h
		mov bx,KbdMap
		xlatb
		cmp al,27			; <ESC> aborts (DOS geeks)
		je ac2
		cmp al,3			; So does Ctrl-C (UNIX geeks)
		jne ac1				; Unknown key... try again
ac2:						; If we get here, ABORT!
                mov si,aborted_msg
                ; Fall through to abort_load
;
; abort_load: Called by various routines which wants to print a fatal
;             error message and return to the command prompt.  Since this
;             may happen at just about any stage of the boot process, assume
;             our state is messed up, and just reset the segment registers
;             and the stack forcibly.
;
;             SI    = offset (in _text) of error message to print
;
abort_load:
                mov ax,cs                       ; Restore CS = DS = ES
                mov ds,ax
                mov es,ax
                cli
                mov sp,StackBuf-2*3    		; Reset stack
                mov ss,ax                       ; Just in case...
                sti
                call writestr                   ; Expects SI -> error msg
al_ok:          jmp enter_command               ; Return to command prompt
;
; End of abort_check
;
ac_ret:         popa
                ret

;
; searchdir: Search the root directory for a pre-mangled filename in
;	     DS:DI.  This routine is similar to the one in the boot
;	     sector, but is a little less Draconian when it comes to
;	     error handling, plus it reads the root directory in
;	     larger chunks than a sector at a time (which is probably
;	     a waste of coding effort, but I like to do things right).
;
;	     NOTE: This file considers finding a zero-length file an
;	     error.  This is so we don't have to deal with that special
;	     case elsewhere in the program (most loops have the test
;	     at the end).
;
;	     If successful:
;		ZF clear
;		SI	= cluster # for the first cluster
;		DX:AX	= file length in bytes
;	     If unsuccessful
;		ZF set
;

searchdir:
		mov ax,[bsRootDirEnts]
		mov [DirScanCtr],ax
		mov ax,[RootDirSize]
		mov [DirBlocksLeft],ax
		mov ax,[RootDir1]
		mov dx,[RootDir2]
scan_group:
		mov bp,[DirBlocksLeft]
		and bp,bp
		jz dir_return
		cmp bp,[BufSafeSec]
		jna load_last
		mov bp,[BufSafeSec]
load_last:
		sub [DirBlocksLeft],bp
		push ax
		push dx
		mov ax,[bsBytesPerSec]
		mul bp
		add ax,trackbuf-31
		mov [EndofDirSec],ax	; End of loaded
		pop dx
		pop ax
		push bp			; Save number of sectors
		push ax			; Save present location
		push dx
		push di			; Save name
		mov bx,trackbuf
		call getlinsec
		pop di
		pop dx
		pop ax
		pop bp
		mov si,trackbuf
dir_test_name:	cmp byte [si],0		; Directory high water mark
		je dir_return		; Failed
                test byte [si+11],018h	; Check it really is a file
                jnz dir_not_this
		push di
		push si
		mov cx,11		; Filename = 11 bytes
		repe cmpsb
		pop si
		pop di
		je dir_success
dir_not_this:   add si,byte 32
		dec word [DirScanCtr]
		jz dir_return		; Out of it...
		cmp si,[EndofDirSec]
		jb dir_test_name
		add ax,bp		; Increment linear sector number
		adc dx,byte 0
		jmp short scan_group
dir_success:
		mov ax,[si+28]		; Length of file
		mov dx,[si+30]
		mov si,[si+26]		; Cluster pointer
		mov bx,ax
		or bx,dx		; Sets ZF iff DX:AX is zero
dir_return:
		ret

;
; writechr:	Write a single character in AL to the screen without
;		mangling any registers
;
writechr:
		pusha
		mov ah,0Eh
		mov bx,0007h		; white text on this page
		int 10h
		popa
		ret

;
; adjust_screen: Set the internal variables associated with the screen size.
;		This is a subroutine in case we're loading a custom font.
;
adjust_screen:
                mov al,[BIOS_vidrows]
                and al,al
                jnz vidrows_is_ok
                mov al,24                       ; No vidrows in BIOS, assume 25
						; (Remember: vidrows == rows-1)
vidrows_is_ok:  mov [VidRows],al
                mov ah,0fh
                int 10h                         ; Read video state
                mov [TextPage],bh
                dec ah                          ; Store count-1 (same as rows)
                mov [VidCols],ah
bf_ret:		ret

;
; loadfont:	Load a .psf font file and install it onto the VGA console
;		(if we're not on a VGA screen then ignore.)  It is called with
;		SI and DX:AX set by routine searchdir
;
loadfont:
		mov bx,trackbuf			; The trackbuf is >= 16K; the part
		mov cx,[BufSafe]		; of a PSF file we care about is no
		call getfssec			; more than 8K+4 bytes

		mov ax,[trackbuf]		; Magic number
		cmp ax,0436h
		jne bf_ret

		mov al,[trackbuf+2]		; File mode
		cmp al,3			; Font modes 0-3 supported
		ja bf_ret

		mov bh,byte [trackbuf+3]	; Height of font
		cmp bh,2			; VGA minimum
		jb bf_ret
		cmp bh,32			; VGA maximum
		ja bf_ret

		mov bp,trackbuf+4		; Address of font data
		xor bl,bl
		mov cx,256
		xor dx,dx
		mov ax,1110h
		int 10h				; Load into VGA RAM

		xor bl,bl
		mov ax,1103h			; Select page 0
		int 10h

		jmp short adjust_screen

;
; loadkeys:	Load a LILO-style keymap; SI and DX:AX set by searchdir
;
loadkeys:
		and dx,dx			; Should be 256 bytes exactly
		jne loadkeys_ret
		cmp ax,256
		jne loadkeys_ret

		mov bx,trackbuf
		mov cx,1			; 1 cluster should be >= 256 bytes
		call getfssec

		mov si,trackbuf
		mov di,KbdMap
		mov cx,256 >> 2
		rep movsd

loadkeys_ret:	ret
		
;
; get_msg_file: Load a text file and write its contents to the screen,
;               interpreting color codes.  Is called with SI and DX:AX
;               set by routine searchdir
;
get_msg_file:
                mov word [NextCharJump],msg_putchar ; State machine for color
                mov byte [TextAttribute],07h	; Default grey on white
                pusha
                mov bh,[TextPage]
                mov ah,03h                      ; Read cursor position
                int 10h
                mov [CursorDX],dx
                popa
get_msg_chunk:  push ax                         ; DX:AX = length of file
                push dx
		mov bx,trackbuf
		mov cx,[BufSafe]
		call getfssec
                pop dx
                pop ax
		push si				; Save current cluster
		mov si,trackbuf
		mov cx,[BufSafeBytes]		; No more than many bytes
print_msg_file: push cx
                push ax
		push dx
		lodsb
                cmp al,1Ah                      ; ASCII EOF?
		je msg_done_pop
                call [NextCharJump]		; Do what shall be done
		pop dx
		pop ax
                pop cx
		sub ax,byte 1
		sbb dx,byte 0
		mov bx,ax
		or bx,dx
		jz msg_done
		loop print_msg_file
		pop si
		jmp short get_msg_chunk
msg_done_pop:
                add sp,byte 6			; Lose 3 words on the stack
msg_done:
		pop si
		ret
msg_putchar:                                    ; Normal character
                cmp al,0Fh                      ; ^O = color code follows
                je msg_ctrl_o
                cmp al,0Dh                      ; Ignore <CR>
                je msg_ignore
                cmp al,0Ah                      ; <LF> = newline
                je msg_newline
                cmp al,0Ch                      ; <FF> = clear screen
                je msg_formfeed
                mov bx,[TextAttrBX]
                mov ah,09h                      ; Write character/attribute
                mov cx,1                        ; One character only
                int 10h                         ; Write to screen
                mov al,[CursorCol]
                inc ax
                cmp al,[VidCols]
                ja msg_newline
                mov [CursorCol],al
msg_gotoxy:     mov bh,[TextPage]
                mov dx,[CursorDX]
                mov ah,02h                      ; Set cursor position
                int 10h
msg_ignore:     ret
msg_ctrl_o:                                     ; ^O = color code follows
                mov word [NextCharJump],msg_setbg
                ret
msg_newline:                                    ; Newline char or end of line
                mov byte [CursorCol],0
                mov al,[CursorRow]
                inc ax
                cmp al,[VidRows]
                ja msg_scroll
                mov [CursorRow],al
                jmp short msg_gotoxy
msg_scroll:     xor cx,cx                       ; Upper left hand corner
                mov dx,[ScreenSize]
                mov [CursorRow],dh		; New cursor at the bottom
                mov bh,[TextAttribute]
                mov ax,0601h                    ; Scroll up one line
                int 10h
                jmp short msg_gotoxy
msg_formfeed:                                   ; Form feed character
                xor cx,cx
                mov [CursorDX],cx		; Upper lefthand corner
                mov dx,[ScreenSize]
                mov bh,[TextAttribute]
                mov ax,0600h                    ; Clear screen region
                int 10h
                jmp short msg_gotoxy
msg_setbg:                                      ; Color background character
                call unhexchar
                jc msg_color_bad
                shl al,4
                mov [TextAttribute],al
                mov word [NextCharJump],msg_setfg
                ret
msg_setfg:                                      ; Color foreground character
                call unhexchar
                jc msg_color_bad
                or [TextAttribute],al		; setbg set foreground to 0
                mov word [NextCharJump],msg_putchar
                ret
msg_color_bad:
                mov byte [TextAttribute],07h	; Default attribute
                mov word [NextCharJump],msg_putchar
                ret

;
; open,getc:	Load a file a character at a time for parsing in a manner
;		similar to the C library getc routine.	Only one simultaneous
;		use is supported.  Note: "open" trashes the trackbuf.
;
;		open:	Input:	mangled filename in DS:DI
;			Output: ZF set on file not found or zero length
;
;		getc:	Output: CF set on end of file
;				Character loaded in AL
;
open:
		call searchdir
		jz open_return
		pushf
		mov [FBytes1],ax
		mov [FBytes2],dx
		add ax,[ClustSize]
		adc dx,byte 0
		sub ax,byte 1
		sbb dx,byte 0
		div word [ClustSize]
		mov [FClust],ax		; Number of clusters
		mov [FNextClust],si	; Cluster pointer
		mov ax,[EndOfGetCBuf]	; Pointer at end of buffer ->
		mov [FPtr],ax		;  nothing loaded yet
		popf			; Restore no ZF
open_return:	ret

;
getc:
		stc			; If we exit here -> EOF
		mov ecx,[FBytes]
		jecxz getc_ret
		mov si,[FPtr]
		cmp si,[EndOfGetCBuf]
		jb getc_loaded
		; Buffer empty -- load another set
		mov cx,[FClust]
		cmp cx,[BufSafe]
		jna getc_oksize
		mov cx,[BufSafe]
getc_oksize:	sub [FClust],cx		; Reduce remaining clusters
		mov si,[FNextClust]
		mov bx,getcbuf
		push bx
		push es			; ES may be != DS, save old ES
		push ds			; Trackbuf is in DS, not ES
		pop es
		call getfssec		; Load a trackbuf full of data
		mov [FNextClust],si	; Store new next pointer
		pop es			; Restore ES
		pop si			; SI -> newly loaded data
getc_loaded:	lodsb			; Load a byte
		mov [FPtr],si		; Update next byte pointer
		dec dword [FBytes]	; Update bytes left counter (CF = 1)
		clc			; Not EOF
getc_ret:	ret

;
; ungetc:	Push a character (in AL) back into the getc buffer
;		Note: if more than one byte is pushed back, this may cause
;		bytes to be written below the getc buffer boundary.  If there
;		is a risk for this to occur, the getcbuf base address should
;		be moved up.
;
ungetc:
		mov si,[FPtr]
		dec si
		mov [si],al
		mov [FPtr],si
		inc dword [FBytes]
		ret

;
; skipspace:	Skip leading whitespace using "getc".  If we hit end-of-line
;		or end-of-file, return with carry set; ZF = true of EOF
;		ZF = false for EOLN; otherwise CF = ZF = 0.
;
;		Otherwise AL = first character after whitespace
;
skipspace:
skipspace_loop: call getc
		jc skipspace_eof
		cmp al,1Ah			; DOS EOF
		je skipspace_eof
		cmp al,0Ah
		je skipspace_eoln
		cmp al,' '
		jbe skipspace_loop
		ret				; CF = ZF = 0
skipspace_eof:	cmp al,al			; Set ZF
		stc				; Set CF
		ret
skipspace_eoln: add al,0FFh			; Set CF, clear ZF
		ret

;
; getkeyword:	Get a keyword from the current "getc" file; only the two
;		first characters are considered significant.
;
;		Lines beginning with ASCII characters 33-47 are treated
;		as comments and ignored; other lines are checked for
;		validity by scanning through the keywd_table.
;
;		The keyword and subsequent whitespace is skipped.
;
;		On EOF, CF = 1; otherwise, CF = 0, AL:AH = lowercase char pair
;
getkeyword:
gkw_find:	call skipspace
		jz gkw_eof		; end of file
		jc gkw_find		; end of line: try again
		cmp al,'0'
		jb gkw_skipline		; skip comment line
		push ax
		call getc
		pop bx
		jc gkw_eof
		mov bh,al		; Move character pair into BL:BH
		or bx,2020h		; Lower-case it
		mov si,keywd_table
gkw_check:	lodsw
		and ax,ax
		jz gkw_badline		; Bad keyword, write message
		cmp ax,bx
		jne gkw_check
		push ax
gkw_skiprest:
		call getc
		jc gkw_eof_pop
		cmp al,'0'
		ja gkw_skiprest
		call ungetc
		call skipspace
		jz gkw_eof_pop
                jc gkw_missingpar       ; Missing parameter after keyword
		call ungetc		; Return character to buffer
		clc			; Successful return
gkw_eof_pop:	pop ax
gkw_eof:	ret			; CF = 1 on all EOF conditions
gkw_missingpar: pop ax
                mov si,err_noparm
                call writestr
                jmp gkw_find
gkw_badline_pop: pop ax
gkw_badline:	mov si,err_badcfg
		call writestr
		jmp short gkw_find
gkw_skipline:	cmp al,10		; Scan for LF
		je gkw_find
		call getc
		jc gkw_eof
		jmp short gkw_skipline

;
; getint:	Load an integer from the getc file.
;		Return CF if error; otherwise return integer in EBX
;
getint:
		mov di,NumBuf
gi_getnum:	cmp di,NumBufEnd	; Last byte in NumBuf
		jae gi_loaded
		push di
		call getc
		pop di
		jc gi_loaded
		stosb
		cmp al,'-'
		jnb gi_getnum
		call ungetc		; Unget non-numeric
gi_loaded:	mov byte [di],0
		mov si,NumBuf
		; Fall through to parseint

;
; parseint:	Convert an integer to a number in EBX
;		Get characters from string in DS:SI
;		Return CF on error
;		DS:SI points to first character after number
;
;               Syntaxes accepted: [-]dec, [-]0+oct, [-]0x+hex, val+K, val+M
;
parseint:
                push eax
                push ecx
		push bp
		xor eax,eax		; Current digit (keep eax == al)
		mov ebx,eax		; Accumulator
		mov ecx,ebx		; Base
                xor bp,bp               ; Used for negative flag
pi_begin:	lodsb
		cmp al,'-'
		jne pi_not_minus
		xor bp,1		; Set unary minus flag
		jmp short pi_begin
pi_not_minus:
		cmp al,'0'
		jb pi_err
		je pi_octhex
		cmp al,'9'
		ja pi_err
		mov cl,10		; Base = decimal
		jmp short pi_foundbase
pi_octhex:
		lodsb
		cmp al,'0'
		jb pi_km		; Value is zero
		or al,20h		; Downcase
		cmp al,'x'
		je pi_ishex
		cmp al,'7'
		ja pi_err
		mov cl,8		; Base = octal
		jmp short pi_foundbase
pi_ishex:
		mov al,'0'		; No numeric value accrued yet
		mov cl,16		; Base = hex
pi_foundbase:
                call unhexchar
                jc pi_km                ; Not a (hex) digit
                cmp al,cl
		jae pi_km		; Invalid for base
		imul ebx,ecx		; Multiply accumulated by base
                add ebx,eax             ; Add current digit
		lodsb
		jmp short pi_foundbase
pi_km:
		dec si			; Back up to last non-numeric
		lodsb
		or al,20h
		cmp al,'k'
		je pi_isk
		cmp al,'m'
		je pi_ism
		dec si			; Back up
pi_fini:	and bp,bp
		jz pi_ret		; CF=0!
		neg ebx			; Value was negative
pi_done:	clc
pi_ret:		pop bp
                pop ecx
                pop eax
		ret
pi_err:		stc
		jmp short pi_ret
pi_isk:		shl ebx,10		; x 2^10
		jmp short pi_done
pi_ism:		shl ebx,20		; x 2^20
		jmp short pi_done

;
; unhexchar:    Convert a hexadecimal digit in AL to the equivalent number;
;               return CF=1 if not a hex digit
;
unhexchar:
                cmp al,'0'
		jb uxc_ret		; If failure, CF == 1 already
                cmp al,'9'
                ja uxc_1
		sub al,'0'		; CF <- 0
		ret
uxc_1:          or al,20h		; upper case -> lower case
		cmp al,'a'
                jb uxc_ret		; If failure, CF == 1 already
                cmp al,'f'
                ja uxc_err
                sub al,'a'-10           ; CF <- 0
                ret
uxc_err:        stc
uxc_ret:	ret

;
;
; getline:	Get a command line, converting control characters to spaces
;               and collapsing streches to one; a space is appended to the
;               end of the string, unless the line is empty.
;		The line is terminated by ^J, ^Z or EOF and is written
;		to ES:DI.  On return, DI points to first char after string.
;		CF is set if we hit EOF.
;
getline:
		call skipspace
                mov dl,1                ; Empty line -> empty string.
                jz gl_eof               ; eof
                jc gl_eoln              ; eoln
		call ungetc
gl_fillloop:	push dx
		push di
		call getc
		pop di
		pop dx
		jc gl_ret		; CF set!
		cmp al,' '
		jna gl_ctrl
		xor dx,dx
gl_store:	stosb
		jmp short gl_fillloop
gl_ctrl:	cmp al,10
		je gl_ret		; CF clear!
		cmp al,26
		je gl_eof
		and dl,dl
		jnz gl_fillloop		; Ignore multiple spaces
		mov al,' '		; Ctrl -> space
		inc dx
		jmp short gl_store
gl_eoln:        clc                     ; End of line is not end of file
                jmp short gl_ret
gl_eof:         stc
gl_ret:		pushf			; We want the last char to be space!
		and dl,dl
		jnz gl_xret
		mov al,' '
		stosb
gl_xret:	popf
		ret


%ifdef debug		; This code for debugging only
;
; dumpregs:	Dumps the contents of all registers
;
                assume ds:_text, es:NOTHING, fs:NOTHING, gs:NOTHING
dumpregs	proc near		; When calling, IP is on stack
		pushf			; Store flags
		pusha
		push ds
		push es
		push fs
		push gs
		push cs			; Set DS <- CS
		pop ds
		cld			; Clear direction flag
		mov si,offset crlf
		call writestr
		mov bx,sp
		add bx,byte 26
		mov si,offset regnames
		mov cx,2		; 2*7 registers to dump
dump_line:	push cx
		mov cx,7		; 7 registers per line
dump_reg:	push cx
		mov cx,4		; 4 characters/register name
wr_reg_name:	lodsb
		call writechr
		loop wr_reg_name
		mov ax,ss:[bx]
		dec bx
		dec bx
		call writehex
		pop cx
		loop dump_reg
		mov al,0Dh		; <CR>
		call writechr
		mov al,0Ah		; <LF>
		call writechr
		pop cx
		loop dump_line
		pop gs
		pop fs
		pop es
		pop ds
		popa			; Restore the remainder
		popf			; Restore flags
		ret
dumpregs	endp

regnames	db ' IP: FL: AX: CX: DX: BX: SP: BP: SI: DI: DS: ES: FS: GS:'

;
; writehex:	Writes a 16-bit hexadecimal number (in AX)
;
writehex	proc near
		push bx
		push cx
		mov cx,4		; 4 numbers
write_hexdig:	xor bx,bx
		push cx
		mov cx,4		; 4 bits/digit
xfer_digit:	shl ax,1
		rcl bx,1
		loop xfer_digit
		push ax
		mov ax,bx
		or al,'0'
		cmp al,'9'
		jna ok_digit
		add al,'A'-'0'-10
ok_digit:	call writechr
		pop ax
		pop cx
		loop write_hexdig
		pop cx
		pop bx
		ret
writehex	endp

debug_magic	dw 0D00Dh

%endif ; debug
;
; mangle_name: Mangle a DOS filename pointed to by DS:SI into a buffer pointed
;	       to by ES:DI; ends on encountering any whitespace
;

mangle_name:
		mov cx,11			; # of bytes to write
mn_loop:
		lodsb
		cmp al,' '			; If control or space, end
		jna mn_end
		cmp al,'.'			; Period -> space-fill
		je mn_is_period
		cmp al,'a'
		jb mn_not_lower
		cmp al,'z'
		ja mn_not_uslower
		sub al,020h
		jmp short mn_not_lower
mn_is_period:	mov al,' '			; We need to space-fill
mn_period_loop: cmp cx,3			; If <= 3 characters left
		jbe mn_loop			; Just ignore it
		stosb				; Otherwise, write a period
		loop mn_period_loop		; Dec CX and (always) jump
mn_not_uslower: cmp al,ucase_low
		jb mn_not_lower
		cmp al,ucase_high
		ja mn_not_lower
		mov bx,ucase_tab-ucase_low
                cs xlatb
mn_not_lower:	stosb
		loop mn_loop			; Don't continue if too long
mn_end:
		mov al,' '			; Space-fill name
		rep stosb			; Doesn't do anything if CX=0
		ret				; Done

;
; Upper-case table for extended characters; this is technically code page 865,
; but code page 437 users will probably not miss not being able to use the
; cent sign in kernel images too much :-)
;
; The table only covers the range 129 to 164; the rest we can deal with.
;
ucase_low	equ 129
ucase_high	equ 164
ucase_tab	db 154, 144, 'A', 142, 'A', 143, 128, 'EEEIII'
		db 142, 143, 144, 146, 146, 'O', 153, 'OUUY', 153, 154
		db 157, 156, 157, 158, 159, 'AIOU', 165

;
; unmangle_name: Does the opposite of mangle_name; converts a DOS-mangled
;                filename to the conventional representation.  This is needed
;                for the BOOT_IMAGE= parameter for the kernel.
;                NOTE: A 13-byte buffer is mandatory, even if the string is
;                known to be shorter.
;
;                DS:SI -> input mangled file name
;                ES:DI -> output buffer
;
;                On return, DI points to the first byte after the output name,
;                which is set to a null byte.
;
unmangle_name:
                push si                 ; Save pointer to original name
                mov cx,8
                mov bp,di
un_copy_body:   lodsb
                call lower_case
                stosb
                cmp al,' '
                jbe un_cb_space
                mov bp,di               ; Position of last nonblank+1
un_cb_space:    loop un_copy_body
                mov di,bp
                mov al,'.'              ; Don't save
                stosb
                mov cx,3
un_copy_ext:    lodsb
                call lower_case
                stosb
                cmp al,' '
                jbe un_ce_space
                mov bp,di
un_ce_space:    loop un_copy_ext
                mov di,bp
                mov byte [es:di], 0
                pop si
                ret

;
; lower_case: Lower case a character in AL
;
lower_case:
                cmp al,'A'
                jb lc_ret
                cmp al,'Z'
                ja lc_1
                or al,20h
                ret
lc_1:           cmp al,lcase_low
                jb lc_ret
                cmp al,lcase_high
                ja lc_ret
                push bx
                mov bx,lcase_tab-lcase_low
               	cs xlatb
                pop bx
lc_ret:         ret

;
; Lower-case table for codepage 865
;
lcase_low       equ 128
lcase_high      equ 165
lcase_tab       db 135, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138
                db 139, 140, 141, 132, 134, 130, 145, 145, 147, 148, 149
                db 150, 151, 152, 148, 129, 155, 156, 155, 158, 159, 160
                db 161, 162, 163, 164, 164
;
; Various initialized or semi-initialized variables
;
copyright_str   db '  Copyright (C) 1994-', year, ' H. Peter Anvin'
		db 0Dh, 0Ah, 0
boot_prompt	db 'boot: ',0
wipe_char	db 08h, ' ', 08h, 0
err_notfound	db 'Could not find kernel image: ',0
err_notkernel	db 0Dh, 0Ah, 'Invalid or corrupt kernel image: ',0
err_not386	db 'It appears your computer uses a 286 or lower CPU.'
		db 0Dh, 0Ah
		db 'You cannot run Linux unless you have a 386 or higher CPU'
		db 0Dh, 0Ah
		db 'in your machine.  If you get this message in error, hold'
		db 0Dh, 0Ah
		db 'down the Ctrl key while booting, and I will take your'
		db 0Dh, 0Ah
		db 'word for it.', 0Dh, 0Ah, 0
err_noram	db 'It appears your computer has less than 608K of low ("DOS")'
		db 0Dh, 0Ah
		db 'RAM.  Linux needs at least this amount to boot.  If you get'
		db 0Dh, 0Ah
		db 'this message in error, hold down the Ctrl key while'
		db 0Dh, 0Ah
		db 'booting, and I will take your word for it.', 0Dh, 0Ah, 0
err_badcfg      db 'Unknown keyword in syslinux.cfg.', 0Dh, 0Ah, 0
err_noparm      db 'Missing parameter in syslinux.cfg.', 0Dh, 0Ah, 0
err_noinitrd    db 0Dh, 0Ah, 'Could not find ramdisk image: ', 0
err_nohighmem   db 'Not enough memory to load specified kernel.', 0Dh, 0Ah, 0
err_highload    db 0Dh, 0Ah, 'Kernel transfer failure.', 0Dh, 0Ah, 0
err_oldkernel   db 'Cannot load a ramdisk with an old kernel image.'
                db 0Dh, 0Ah, 0
loading_msg     db 'Loading ', 0
dotdot_msg      db '.'
dot_msg         db '.', 0
aborted_msg	db ' aborted.'			; Fall through to crlf_msg!
crlf_msg	db 0Dh, 0Ah, 0
syslinux_cfg	db 'SYSLINUXCFG'
;
; Command line options we'd like to take a look at
;
; mem= and vga= are handled as normal 32-bit integer values
initrd_cmd	db 'initrd='
initrd_cmd_len	equ 7
;
; Config file keyword table
;
		align 2
keywd_table	db 'ap' ; append
		db 'de' ; default
		db 'ti' ; timeout
		db 'fo'	; font
		db 'kb' ; kbd
		db 'di' ; display
		db 'pr' ; prompt
		db 'la' ; label
                db 'im' ; implicit
		db 'ke' ; kernel
;		db 'ru'	; run
;		db 'bo'	; bootsec
		db 'f1' ; F1
		db 'f2' ; F2
		db 'f3' ; F3
		db 'f4' ; F4
		db 'f5' ; F5
		db 'f6' ; F6
		db 'f7' ; F7
		db 'f8' ; F8
		db 'f9' ; F9
		db 'f0' ; F10
		dw 0
;
; Misc initialized (data) variables
;
AppendLen       dw 0                    ; Bytes in append= command
KbdTimeOut      dw 0                    ; Keyboard timeout (if any)
FKeyMap		dw 0			; Bitmap for F-keys loaded
CmdLinePtr	dw cmd_line_here	; Command line advancing pointer
initrd_flag	equ $
initrd_ptr	dw 0			; Initial ramdisk pointer/flag
VKernelCtr	dw 0			; Number of registered vkernels
ForcePrompt	dw 0			; Force prompt
AllowImplicit   dw 1                    ; Allow implicit kernels
;
; Stuff for the command line; we do some trickery here with equ to avoid
; tons of zeros appended to our file and wasting space
;
linuxauto_cmd	db 'linux '
auto_cmd	db 'auto',0
linuxauto_len   equ $-linuxauto_cmd
auto_len        equ $-auto_cmd
boot_image      db 'BOOT_IMAGE='
boot_image_len  equ $-boot_image
                align 4, db 0		; For the good of REP MOVSD
command_line	equ $
default_cmd	equ $+(max_cmd_len+2)
ldlinux_end	equ default_cmd+(max_cmd_len+1)
kern_cmd_len    equ ldlinux_end-command_line
ldlinux_len	equ ldlinux_end-ldlinux_magic
;
; Put the getcbuf right after the code, aligned on a sector boundary
;
end_of_code	equ (ldlinux_end-bootsec)+7C00h
getcbuf		equ (end_of_code + 511) & 0FE00h
