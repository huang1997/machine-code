;; -*- mode: scheme; coding: utf-8 -*-
;; Copyright © 2010, 2012, 2016, 2017, 2018 Göran Weinholt <goran@weinholt.se>
;; SPDX-License-Identifier: MIT
#!r6rs

;; Disassembler for Intel 8080/8085

(library (machine-code disassembler i8080)
  (export
    get-instruction invalid-opcode?)
  (import
    (rnrs (6))
    (machine-code disassembler private))

  ;; Intel 8080 opcode table. These are "undocumented": arhl, dsub,
  ;; jx5, jnx5, ldhi, ldsi, lhlx, rdel, rstv, shlx.
  (define opcodes
    '#((nop) (lxi b d16) (stax b) (inx b) (inr b) (dcr b) (mvi b d8) (rlc)
       (dsub) (dad b) (ldax b) (dcx b) (inr c) (dcr c) (mvi c d8) (rrc)
       ;; 10
       (arhl) (lxi d d16) (stax d) (inx d) (inr d) (dcr d) (mvi d d8) (ral)
       (rdel) (dad d) (ldax d) (dcx d) (inr e) (dcr e) (mvi e d8) (rar)
       ;; 20
       (rim) (lxi h d16) (shld addr16) (inx h) (inr h) (dcr h) (mvi h d8) (daa)
       (ldhi d8) (dad h) (lhld addr16) (dcx h) (inr l) (dcr l) (mvi l d8) (cma)
       ;; 30
       (sim) (lxi sp d16) (sta addr) (inx sp) (inr m) (dcr m) (mvi m d8) (stc)
       (ldsi d8) (dad sp) (lda addr) (dcx sp) (inr a) (dcr a) (mvi a d8) (cmc)
       ;; 40
       (mov b b) (mov b c) (mov b d) (mov b e) (mov b h) (mov b l) (mov b m) (mov b a)
       (mov c b) (mov c c) (mov c d) (mov c e) (mov c h) (mov c l) (mov c m) (mov c a)
       ;; 50
       (mov d b) (mov d c) (mov d d) (mov d e) (mov d h) (mov d l) (mov d m) (mov d a)
       (mov e b) (mov e c) (mov e d) (mov e e) (mov e h) (mov e l) (mov e m) (mov e a)
       ;; 60
       (mov h b) (mov h c) (mov h d) (mov h e) (mov h h) (mov h l) (mov h m) (mov h a)
       (mov l b) (mov l c) (mov l d) (mov l e) (mov l h) (mov l l) (mov l m) (mov l a)
       ;; 70
       (mov m b) (mov m c) (mov m d) (mov m e) (mov m h) (mov m l) (hlt) (mov m a)
       (mov a b) (mov a c) (mov a d) (mov a e) (mov a h) (mov a l) (mov a m) (mov a a)
       ;; 80
       (add b) (add c) (add d) (add e) (add h) (add l) (add m) (add a)
       (adc b) (adc c) (adc d) (adc e) (adc h) (adc l) (adc m) (adc a)
       ;; 90
       (sub b) (sub c) (sub d) (sub e) (sub h) (sub l) (sub m) (sub a)
       (sbb b) (sbb c) (sbb d) (sbb e) (sbb h) (sbb l) (sbb m) (sbb a)
       ;; a0
       (ana b) (ana c) (ana d) (ana e) (ana h) (ana l) (ana m) (ana a)
       (xra b) (xra c) (xra d) (xra e) (xra h) (xra l) (xra m) (xra a)
       ;; b0
       (ora b) (ora c) (ora d) (ora e) (ora h) (ora l) (ora m) (ora a)
       (cmp b) (cmp c) (cmp d) (cmp e) (cmp h) (cmp l) (cmp m) (cmp a)
       ;; c0
       (rnz) (pop b) (jnz Jw) (jmp Jw) (cnz Jw) (push b) (adi d8) (rst 0)
       (rz) (ret) (jz Jw) (rstv) (cz Jw) (call Jw) (aci d8) (rst 1)
       ;; d0
       (rnc) (pop d) (jnz Jw) (out d8) (cnc Jw) (push d) (sui d8) (rst 2)
       (rc) (shlx) (jc Jw) (in d8) (cc Jw) (jnx5 Jw) (sbi d8) (rst 3)
       ;; e0
       (rpo) (pop h) (jpo Jw) (xthl) (cpo Jw) (push h) (ani d8) (rst 4)
       (rpe) (pchl) (jpe Jw) (xchg) (cpe Jw) (lhlx) (xri d8) (rst 5)
       ;; f0
       (rp) (pop psw) (jp Jw) (di) (cp Jw) (push psw) (ori d8) (rst 6)
       (rm) (sphl) (jm Jw) (ei) (cm Jw) (jx5 Jw) (cpi d8) (rst 7)))

;;; Port input
  (define (really-get-bytevector-n port n collect tag)
    (let ((bv (get-bytevector-n port n)))
      (unless (eof-object? bv)
        (if collect (apply collect tag (bytevector->u8-list bv))))
      (when (or (eof-object? bv) (< (bytevector-length bv) n))
        (raise-UD "End of file inside instruction"))
      bv))

  (define (get-u8/collect port collect tag)
    (bytevector-u8-ref (really-get-bytevector-n port 1 collect tag)
                       0))

  (define (get-u16/collect port collect tag)
    (bytevector-u16-ref (really-get-bytevector-n port 2 collect tag)
                        0 (endianness little)))

;;; Disassembler

  (define (get-instruction port collect pc)
    (define (get-operand type)
      (case type
        ((addr) (list 'mem8+ (get-u16/collect port collect 'immediate)))
        ((addr16) (list 'mem16+ (get-u16/collect port collect 'immediate)))
        ((Jw) (get-u16/collect port collect 'disp))
        ((d8) (get-u8/collect port collect 'immediate))
        ((d16) (get-u16/collect port collect 'immediate))
        ((m) '(mem8+ m))                ;register pair H:L
        ((psw b c d e h l a sp) type)
        ((0 1 2 3 4 5 6 7) type)
        (else (list 'fixme type))))
    (define (get-operands opcode-table opcode)
      (let ((instr (and (> (vector-length opcode-table) opcode)
                        (vector-ref opcode-table opcode))))
        (cons (car instr)
              (map-in-order get-operand (cdr instr)))))
    (if (port-eof? port)
        (eof-object)
        (get-operands opcodes (get-u8/collect port collect 'opcode))))

  ;; Generic disassembler support.
  (let ((min 1) (max 3))
    (define (wrap-get-instruction)
      (define get-instruction*
        (case-lambda
          ((port)
           (get-instruction port #f #f))
          ((port collect)
           (get-instruction port collect #f))
          ((port collect pc)
           (get-instruction port collect pc))))
      get-instruction*)
    (register-disassembler
     (make-disassembler 'i8080 min max (wrap-get-instruction)))))
