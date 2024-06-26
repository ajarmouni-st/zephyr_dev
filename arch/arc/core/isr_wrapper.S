/*
 * Copyright (c) 2014-2015 Wind River Systems, Inc.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/**
 * @file
 * @brief Wrapper around ISRs with logic for context switching
 *
 *
 * Wrapper installed in vector table for handling dynamic interrupts that accept
 * a parameter.
 */

#include <offsets_short.h>
#include <zephyr/toolchain.h>
#include <zephyr/linker/sections.h>
#include <zephyr/sw_isr_table.h>
#include <zephyr/kernel_structs.h>
#include <zephyr/arch/cpu.h>
#include <swap_macros.h>
#include <zephyr/arch/arc/asm-compat/assembler.h>

GTEXT(_isr_wrapper)
GTEXT(_isr_demux)

#if defined(CONFIG_PM)
GTEXT(pm_system_resume)
#endif

/*
The symbols in this file are not real functions, and neither are
_rirq_enter/_firq_enter: they are jump points.

The flow is the following:

ISR -> _isr_wrapper -- + -> _rirq_enter -> _isr_demux -> ISR -> _rirq_exit
			 |
			 + -> _firq_enter -> _isr_demux -> ISR -> _firq_exit

Context switch explanation:

The context switch code is spread in these files:

	isr_wrapper.s, switch.s, swap_macros.h, fast_irq.s, regular_irq.s

IRQ stack frame layout:

	high address

	status32
		pc
	lp_count
	lp_start
	lp_end
	blink
	 r13
	 ...
	sp ->    r0

	low address

The context switch code adopts this standard so that it is easier to follow:

	- r2 contains _kernel.current ASAP, and the incoming thread when we
		transition from outgoing thread to incoming thread

Not loading _kernel into r0 allows loading _kernel without stomping on
the parameter in r0 in arch_switch().


ARCv2 processors have two kinds of interrupts: fast (FIRQ) and regular. The
official documentation calls the regular interrupts 'IRQs', but the internals
of the kernel call them 'RIRQs' to differentiate from the 'irq' subsystem,
which is the interrupt API/layer of abstraction.

For FIRQ, there are two cases, depending upon the value of
CONFIG_RGF_NUM_BANKS.

CONFIG_RGF_NUM_BANKS==1 case:
Scratch registers are pushed onto the current stack just as they are with
RIRQ. See the above frame layout. Unlike RIRQ, the status32_p0 and ilink
registers are where status32 and the program counter are located, so these
need to be pushed.

CONFIG_RGF_NUM_BANKS!=1 case:
The FIRQ handler has its own register bank for general purpose registers,
and thus it doesn't have to save them on a stack. The 'loop' registers
(lp_count, lp_end, lp_start), however, are not present in the
second bank. The handler saves these special registers in unused callee saved
registers (to avoid stack accesses). It is possible to register a FIRQ
handler that operates outside of the kernel, but care must be taken to only
use instructions that only use the banked registers.

The kernel is able to handle transitions to and from FIRQ, RIRQ and threads.
The contexts are saved 'lazily': the minimum amount of work is
done upfront, and the rest is done when needed:

o RIRQ

	All needed registers to run C code in the ISR are saved automatically
	on the outgoing thread's stack: loop, status32, pc, and the caller-
	saved GPRs. That stack frame layout is pre-determined. If returning
	to a thread, the stack is popped and no registers have to be saved by
	the kernel. If a context switch is required, the callee-saved GPRs
	are then saved in the thread's stack.

o FIRQ

	First, a FIRQ can be interrupting a lower-priority RIRQ: if this is
	the case, the FIRQ does not take a scheduling decision and leaves it
	the RIRQ to handle. This limits the amount of code that has to run at
	interrupt-level.

	CONFIG_RGF_NUM_BANKS==1 case:
	Registers are saved on the stack frame just as they are for RIRQ.
	Context switch can happen just as it does in the RIRQ case, however,
	if the FIRQ interrupted a RIRQ, the FIRQ will return from interrupt
	and let the RIRQ do the context switch. At entry, one register is
	needed in order to have code to save other registers. r0 is saved
	first in the stack and restored later

	CONFIG_RGF_NUM_BANKS!=1 case:
	During early initialization, the sp in the 2nd register bank is made to
	refer to _firq_stack. This allows for the FIRQ handler to use its own
	stack. GPRs are banked, loop registers are saved in unused callee saved
	regs upon interrupt entry. If returning to a thread, loop registers are
	restored and the CPU switches back to bank 0 for the GPRs. If a context
	switch is needed, at this point only are all the registers saved.
	First, a  stack frame with the same layout as the automatic RIRQ one is
	created and then the callee-saved GPRs are saved in the stack.
	status32_p0 and ilink are saved in this case, not status32 and pc.
	To create the stack frame, the FIRQ handling code must first go back to
	using bank0 of registers, since that is where the registers containing
	the exiting thread are saved. Care must be taken not to touch any
	register before saving them: the only one usable at that point is the
	stack pointer.

o coop

	When a coop context switch is done, the callee-saved registers are
	saved in the stack. The other GPRs do not need to be saved, since the
	compiler has already placed them on the stack.

For restoring the contexts, there are six cases. In all cases, the
callee-saved registers of the incoming thread have to be restored. Then, there
are specifics for each case:

From coop:

	o to coop

		Do a normal function call return.

	o to any irq

	The incoming interrupted thread has an IRQ stack frame containing the
	caller-saved registers that has to be popped. status32 has to be
	restored, then we jump to the interrupted instruction.

From FIRQ:

	When CONFIG_RGF_NUM_BANKS==1, context switch is done as it is for RIRQ.
	When CONFIG_RGF_NUM_BANKS!=1, the processor is put back to using bank0,
	not bank1 anymore, because it had to save the outgoing context from
	bank0, and now has to load the incoming one into bank0.

	o to coop

	The address of the returning instruction from arch_switch() is loaded
	in ilink and the saved status32 in status32_p0.

	o to any irq

	The IRQ has saved the caller-saved registers in a stack frame, which
	must be popped, and status32 and pc loaded in status32_p0 and ilink.

From RIRQ:

	o to coop

	The interrupt return mechanism in the processor expects a stack frame,
	but the outgoing context did not create one. A fake one is created
	here, with only the relevant values filled in: pc, status32.

	There is a discrepancy between the ABI from the ARCv2 docs,
	including the way the processor pushes GPRs in pairs in the IRQ stack
	frame, and the ABI GCC uses. r13 should be a callee-saved register,
	but GCC treats it as caller-saved. This means that the processor pushes
	it in the stack frame along with r12, but the compiler does not save it
	before entering a function. So, it is saved as part of the callee-saved
	registers, and restored there, but the processor restores it _a second
	time_ when popping the IRQ stack frame. Thus, the correct value must
	also be put in the fake stack frame when returning to a thread that
	context switched out cooperatively.

	o to any irq

	Both types of IRQs already have an IRQ stack frame: simply return from
	interrupt.
 */

SECTION_FUNC(TEXT, _isr_wrapper)
#ifdef CONFIG_ARC_FIRQ
#if CONFIG_RGF_NUM_BANKS == 1
/* free r0 here, use r0 to check whether irq is firq.
 * for rirq,  as sp will not change and r0 already saved, this action
 * in fact is useless
 * for firq,  r0 will be restored later
 */
	push r0
#endif
	lr r0, [_ARC_V2_AUX_IRQ_ACT]
	ffs r0, r0
	cmp r0, 0
#if CONFIG_RGF_NUM_BANKS == 1
	bnz rirq_path
	pop r0
	/* 1-register bank FIRQ handling must save registers on stack */
	_create_irq_stack_frame
	lr r0, [_ARC_V2_STATUS32_P0]
	st_s r0, [sp, ___isf_t_status32_OFFSET]
	st ilink, [sp, ___isf_t_pc_OFFSET]

	mov_s r3, _firq_exit
	mov_s r2, _firq_enter
	j_s [r2]
rirq_path:
	add sp, sp, 4
	mov_s r3, _rirq_exit
	mov_s r2, _rirq_enter
	j_s [r2]
#else
	mov.z r3, _firq_exit
	mov.z r2, _firq_enter
	mov.nz r3, _rirq_exit
	mov.nz r2, _rirq_enter
	j_s [r2]
#endif
#else
	MOVR r3, _rirq_exit
	MOVR r2, _rirq_enter
	j_s [r2]
#endif

/* r0, r1, and r3 will be used in exit_tickless_idle macro */
.macro exit_tickless_idle
#if defined(CONFIG_PM)
	clri r0 /* do not interrupt exiting tickless idle operations */
	MOVR r1, _kernel
	breq r3, 0, _skip_pm_save_idle_exit

	st 0, [r1, _kernel_offset_to_idle] /* zero idle duration */
	PUSHR blink
	jl pm_system_resume
	POPR blink

_skip_pm_save_idle_exit:
	seti r0
#endif
.endm

/* when getting here, r3 contains the interrupt exit stub to call */
SECTION_FUNC(TEXT, _isr_demux)
	PUSHR r3

/* according to ARCv2 ISA, r25, r30, r58, r59 are caller-saved
 * scratch registers, possibly used by interrupt handlers
 */
	PUSHR r25
	PUSHR r30
#ifdef CONFIG_ARC_HAS_ACCL_REGS
	PUSHR r58
#ifndef CONFIG_64BIT
	PUSHR r59
#endif /* !CONFIG_64BIT */
#endif

#ifdef CONFIG_SCHED_THREAD_USAGE
	bl z_sched_usage_stop
#endif

#ifdef CONFIG_TRACING_ISR
	bl sys_trace_isr_enter
#endif
	/* cannot be done before this point because we must be able to run C */
	exit_tickless_idle

	lr r0, [_ARC_V2_ICAUSE]
	/* handle software triggered interrupt */
	lr r3, [_ARC_V2_AUX_IRQ_HINT]
	brne r3, r0, irq_hint_handled
	sr 0, [_ARC_V2_AUX_IRQ_HINT]
irq_hint_handled:

	sub r0, r0, 16

	MOVR r1, _sw_isr_table
	/* SW ISR table entries are 8-bytes wide for 32bit ISA and
	 * 16-bytes wide for 64bit ISA */
	ASLR r0, r0, (ARC_REGSHIFT + 1)
	ADDR r0, r1, r0
	/* ISR into r1 */
	LDR r1, r0, ARC_REGSZ
	jl_s.d [r1]
	/* delay slot: ISR parameter into r0 */
	LDR r0, r0

#ifdef CONFIG_TRACING_ISR
	bl sys_trace_isr_exit
#endif

#ifdef CONFIG_ARC_HAS_ACCL_REGS
#ifndef CONFIG_64BIT
	POPR r59
#endif /* !CONFIG_64BIT */
	POPR r58
#endif

	POPR r30
	POPR r25

	/* back from ISR, jump to exit stub */
	POPR r3
	j_s [r3]
	nop_s
