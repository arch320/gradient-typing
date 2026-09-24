;;; gradient-typing.el --- The text turns into a gradient as you type  -*- lexical-binding: t -*-

;; Original work Copyright (C) 2026 Barrulus
;; Modified work Copyright (C) 2026 Mitsuo Saito
;;
;; Created date 2026-09-20 02:48 +0900

;; Author: Mitsuo Saito <arch320(AT)gmail(DOT)com>
;; Version: 0.1
;; Keywords: convenience, faces
;; URL: http://github.com/arch320/gradient-typing/
;; Compatibility: GNU Emacs 31.1 later
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is *NOT* part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Gradient Typing Effect
;; - Leaves a gradient behind the last character you typed.
;; - Each self-inserted character briefly transitions from the specified color,
;;   to the topmost foreground color.
;; - Naturally smooth, perceptually uniform interpolation
;;   using the CIELAB color space.
;;
;;   It doesn't have the flashy look of a gaming PC xD
;;
;; Basic steps to setup:
;;   1. Place `gradient-typing.el' in your `load-path'.
;;   2. In your `init.el' file
;;         (require 'gradient-typing)
;;         (global-gradient-typing-mode t)
;;
;;   That's all.
;;

;;; Commands:
;;
;; Below are complete command list:
;;
;;  `gdt-clear'
;;    Clear cache and remove all overlay.
;;  `gradient-typing-mode'
;;    Toggle gradient-typing-mode.
;;
;;; Customizable Options:
;;
;; Below are customizable option list:
;;
;;  `gdt-mode-predicate'
;;    Whether to use `gradient-typing-mode' in a buffer.
;;  `gdt-overlay-priority'
;;    Priority to use for gradient overlay.
;;  `gdt-frames'
;;    Delay between gradient frames.
;;  `gdt-pattern'
;;    Number of gradient patterns to be generated.
;;  `gdt-start-color'
;;    Start color of the gradient.
;;

;;; Acknowledgment:
;;
;;   Special thanks to Barrulus for the original idea and inspiration.
;;   This project was heavily inspired by `welding-cursor.el'.
;;
;;   https://github.com/barrulus/forge-cursor
;;

;;
;; Happy Coding !!
;;

;;; SCM Log
;;
;;   $Revision: 50:eef521424bd2 tip $
;;   $Committer: arch320 $
;;   $LastModified: Thu, 24 Sep 2026 19:04:14 +0900 $
;;
;;   $Lastlog: tweak $
;;

;;; ChangeLog
;;
;;   2026/09/24 Ver 0.1 Initial release
;;

;;; Code:

(defconst gradient-typing-vers "$Id: gradient-typing.el,v 50:eef521424bd2 2026-09-24 19:04 +0900 arch320 $"
  "Gradient Typing Effect version.")

;;
;; (@* "Require" )
;;
(eval-when-compile
  (require 'cl-lib)
  (defvar gradient-typing-mode nil
    "Dummy for suppress bytecompiler warning."))

(require 'color)

;;
;; (@* "Customizable variables" )
;;
(defgroup gradient-typing nil
  "Gradient Typing Effect - The text turns into a gradient as you type."
  :group 'convenience
  :prefix "gdt-"
  :link `(url-link
          :tag "GITHUB"
          "http://github.com/arch320/gradient-typing/"))

(defcustom gdt-mode-predicate
  `(and (not (derived-mode . (image-mode doc-view-mode pdf-view-mode vundo-mode)))
		(not ,(eval-when-compile
				(concat "\\`" (regexp-opt '(" *") t)))))
  "Whether to use `gradient-typing-mode' in a buffer.
The predicate is passed as argument to `buffer-match-p', which see."
  :group 'gradient-typing
  :type 'buffer-predicate
  :safe #'booleanp)

(defcustom gdt-overlay-priority 10000
  "Priority to use for gradient overlay."
  :group 'gradient-typing
  :type 'integer)

(defcustom gdt-frames 0.0625
  "Delay between gradient frames.

Note:
Lower values may significantly affect performance."
  :group 'gradient-typing
  :type '(choice (const :tag "Default (16fps)" 0.0625)
                 (float :tag "Custom"))
  :set #'(lambda (sym v)
           (set-default sym (if (> v 0) v (eval (car (get sym 'standard-value)))))))

(defcustom gdt-pattern 8
  "Number of gradient patterns to be generated.

The larger the pattern, the longer the gradient lasts."
  :group 'gradient-typing
  :type 'integer
  :set #'(lambda (sym v)
           (set-default sym (max v 1))))

(defcustom gdt-start-color "White"
  "Start color of the gradient.

This color transitions into the current context color as a gradient."
  :group 'gradient-typing
  :type '(choice (const :tag "Light-bringer" "White")
                 (const :tag "Ectoplasm" ectoplasm)
                 (color :tag "Custom Color"))
  :set #'(lambda (sym v)
           (set-default sym
                        (cond
                         ((eq v 'ectoplasm) (face-attribute 'default :background))
                         (t v)))))

;;
;; (@* "Variable watchers" )
;;
(defun gdt--watcher (sym new op _)
  "Call `gdt-clear-1' when `gdt-pattern' or `gdt-start-color' is set.

`SYM' is SYMBOL is the variable being changed.
`NEW' is the value it will be changed to.
`OP'  is a symbol representing the kind of change."
  (when (and (eq op 'set)
             (fboundp 'gdt-clear-1)
             (not (equal (symbol-value sym) new)))
    (gdt-clear-1)))

(add-variable-watcher 'gdt-pattern     #'gdt--watcher)
(add-variable-watcher 'gdt-start-color #'gdt--watcher)

;;
;; (@* "Internal variables" )
;;
(defvar gdt--cache (make-hash-table :test #'equal)
  "Gradient pattern cache.

KEY:end-color Value:[gradient patten as a vector]")

;;
;; (@* "Gradient" )
;;
(defsubst gdt-rgb-to-hex (rgb)
  "Return a hex-rgb notation for the color `RGB'."
  (apply #'color-rgb-to-hex (append rgb '(2))))

(defun gdt-generate-gradient (start-color end-color &optional size)
  "Return a gradient pattern from `START-COLOR' to `END-COLOR' as a vector.

`SIZE' is the size of the generated gradient pattern.

The colors are converted to CIELAB for perceptually uniform interpolation.
CIELAB - https://en.wikipedia.org/wiki/CIELAB_color_space"
  ;; (benchmark 10000 '(gdt-generate-gradient "Black" "White" 8)) ; => "Elapsed time: 0.154337s"
  ;;   on Samsung Galaxy S25 - GNU Emacs 32.0.50
  (cl-loop
   with n = (or size gdt-pattern)

   with gradient = (make-vector n nil)

   with s-rgb = (or (color-name-to-rgb start-color) '(1.0 1.0 1.0))
   with e-rgb = (or (color-name-to-rgb end-color)   '(0.0 0.0 0.0))

   with s-lab = (apply #'color-srgb-to-lab s-rgb)
   with e-lab = (apply #'color-srgb-to-lab e-rgb)

   for i from 1 to (1- n)
   for j = (/ (float i) n)

   initially do (aset gradient 0 (gdt-rgb-to-hex s-rgb))

   do
   (aset gradient i
         (let* ((lab (cl-mapcar
                      #'(lambda (a b)
                          (+ a (* j (- b a))))
                      s-lab e-lab))

                ;; clamping may introduce a slight error.
                (rgb (mapcar
                      #'(lambda (c)
                          (min 1.0 (max 0.0 c)))
                      (apply #'color-lab-to-srgb lab))))
           (gdt-rgb-to-hex rgb)))

   finally
   return gradient))

(defun gdt-foreground-color-at-point ()
  "Return the foreground color of the topmost context at point."
  (cl-loop
   for face in (ensure-list (face-at-point nil t))
   for color = (face-attribute face :foreground nil 'default)

   when color
   unless (member color '(unspecified "unspecified"))
   return color

   finally
   return (face-attribute 'default :foreground)))

;;
;; (@* "Core" )
;;
(defun gdt-gradient (pos)
  "Set gradient effect at `POS'.

Modified from `welding-cursor.el' by Mitsuo Saito on 2026."
  (when (and (integerp pos) (> pos (point-min)))
    (let* ((overlay (make-overlay (1- pos) pos))
           (i 0)
           (step gdt-pattern)
           fc gr timer)
      (overlay-put overlay 'gdt-overlay 'identify)
      (overlay-put overlay 'priority gdt-overlay-priority)
      (setq timer
            (run-at-time
             0 gdt-frames
             #'(lambda ()
                 (cond*
                  ((or (>= i step)
                       (not (overlayp overlay))
                       (not (overlay-buffer overlay)))
                   (when (overlayp overlay)
                     (delete-overlay overlay))
                   (when (timerp timer)
                     (cancel-timer timer)))

                  ((= i 0)
                   (setq fc (save-excursion
                              (goto-char pos)
                              (gdt-foreground-color-at-point)))
                   (setq gr (or (gethash fc gdt--cache)
                                (puthash fc (gdt-generate-gradient
                                             gdt-start-color fc step)
                                         gdt--cache)))
                   :non-exit)

                  (t
                   (when (overlayp overlay)
                     (overlay-put overlay 'face (list :foreground (aref gr i))))
                   (setq i (1+ i))))))))))

(defun gdt-insert-handler ()
  "Hook function for `post-self-insert-hook'."
  (gdt-gradient (point)))

;;
;; (@* "Misc" )
;;
(defun gdt-clear-1 ()
  "Overwrite!

Note:
This function iterates over all buffers where `gradient-typing-mode' is active.
It widens the buffer restriction and purges all overlays to prevent
some errors(out-of-range,void-variable) and to regenerate the gradient pattern
correctly."
  (clrhash gdt--cache)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when gradient-typing-mode
        (save-restriction
          (widen)
          (remove-overlays (point-min) (point-max) 'gdt-overlay t))))))

(defun gdt-mode-trigger ()
  "Enable `gradient-typing-mode' if conditions are met."
  (when (and (display-graphic-p)
             (not (minibufferp))
             (buffer-match-p gdt-mode-predicate (current-buffer)))
    (gradient-typing-mode 1)))

;;
;; (@* "Interactive" )
;;
(defun gdt-clear ()
  "Activate Rothski device."
  (interactive)
  (gdt-clear-1))

;;
;; (@* "Mode" )
;;
;;;###autoload
(define-minor-mode gradient-typing-mode
  "Gradient Typing Effect.  The text turns into a gradient as you type."
  :group 'gradient-typing
  :lighter "GT"
  (if gradient-typing-mode
      (add-hook 'post-self-insert-hook #'gdt-insert-handler nil t)
    (remove-hook 'post-self-insert-hook #'gdt-insert-handler t)))

;;;###autoload
(define-globalized-minor-mode global-gradient-typing-mode
  gradient-typing-mode
  gdt-mode-trigger
  :group 'gradient-typing)

;;;;;;;;;;;;;;;;;;;;;;;;;

(provide 'gradient-typing)

;;; Local Variables:
;;; indent-tabs-mode: nil
;;; End:

;;
;; $Id: gradient-typing.el,v 50:eef521424bd2 2026-09-24 19:04 +0900 arch320 $
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; gradient-typing.el ends here
