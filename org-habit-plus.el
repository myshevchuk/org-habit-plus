;;; org-habit-plus.el --- The (enhanced) habit tracking code for Org-mode

;; Original Author: John Wiegley
;; Copyright (C) 2009-2015 Free Software Foundation, Inc.

;; Copyright (C) 2015 Michael Shevchuk <m.shev4uk@gmail.com>
;;
;; Author: Michael Shevchuk
;; Keywords: org-mode, habits
;; Homepage: https://github.com/oddious/org-habit-plus
;; Version: 0.1.0

;; This file is not part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This file contains the habit tracking utility for Org-mode.
;; It's code is largly based on the original org-habit code by John Wiegly.
;;
;; The main goal of org-habit-plus is to provide a way to track habits only on certain
;; days of week. The secondary goal (not realized yet) is to make it possible to distinguish between
;; several DONE states.
;;
;; Usage:
;;
;; Load org-habit-plus: (setq org-modules '(maybe-some-module org-habit-pus maybe-some-other-module))
;;
;; For a habit entry, set the HABIT_WEEKDAYS property to a space-separated list of weekdays the task might be done.
;; Currently only day numbers are supported, e.g. 1 for Monday, 2 for Tuesday, etc.
;; For example, if it is some work-related habit, the property might look like this:
;; :HABIT_WEEKDAYS: 1 2 3 4 5
;;
;; WARNING: as for now, expect consistent behaviour only for ".+"-style habits
;;
;; if HABIT_WEEKDAYS is not set (or set to "1 2 3 4 5 6 7"), the results will be similar to those produced
;; by the original org-habit module, except for the "++"-style habits, which didn't work for me with the
;; original module. Sometimes the respective habit graph was fully red, although the habit was done always in time,
;; this weird behaviour was fixed.
;;
;; Although I've happily been using this module for more than a month, some bugs may eventually manifest themselves.
;; Feedback therefore is greately appreciated.
;;
;;; Code:

(require 'org)
(require 'org-agenda)

(eval-when-compile
  (require 'cl-lib))

(defgroup org-habit nil
  "Options concerning habit tracking in Org-mode."
  :tag "Org Habit"
  :group 'org-progress)

(defcustom org-habit-graph-column 40
  "The absolute column at which to insert habit consistency graphs.
Note that consistency graphs will overwrite anything else in the buffer."
  :group 'org-habit
  :type 'integer)

(defcustom org-habit-preceding-days 21
  "Number of days before today to appear in consistency graphs."
  :group 'org-habit
  :type 'integer)

(defcustom org-habit-following-days 7
  "Number of days after today to appear in consistency graphs."
  :group 'org-habit
  :type 'integer)

(defcustom org-habit-show-habits t
  "If non-nil, show habits in agenda buffers."
  :group 'org-habit
  :type 'boolean)

(defcustom org-habit-show-habits-only-for-today t
  "If non-nil, only show habits on today's agenda, and not for future days.
Note that even when shown for future days, the graph is always
relative to the current effective date."
  :group 'org-habit
  :type 'boolean)

(defcustom org-habit-show-all-today nil
  "If non-nil, will show the consistency graph of all habits on
today's agenda, even if they are not scheduled."
  :group 'org-habit
  :type 'boolean)

(defcustom org-habit-today-glyph ?!
  "Glyph character used to identify today."
  :group 'org-habit
  :version "24.1"
  :type 'character)

(defcustom org-habit-completed-glyph ?*
  "Glyph character used to show completed days on which a task was done."
  :group 'org-habit
  :version "24.1"
  :type 'character)

(defcustom org-habit-show-done-always-green nil
  "Non-nil means DONE days will always be green in the consistency graph.
It will be green even if it was done after the deadline."
  :group 'org-habit
  :type 'boolean)

(defface org-habit-clear-face
  '((((background light)) (:background "#8270f9"))
    (((background dark)) (:background "blue")))
  "Face for days on which a task shouldn't be done yet."
  :group 'org-habit
  :group 'org-faces)
(defface org-habit-clear-future-face
  '((((background light)) (:background "#d6e4fc"))
    (((background dark)) (:background "midnight blue")))
  "Face for future days on which a task shouldn't be done yet."
  :group 'org-habit
  :group 'org-faces)

(defface org-habit-ready-face
  '((((background light)) (:background "#4df946"))
    (((background dark)) (:background "forest green")))
  "Face for days on which a task should start to be done."
  :group 'org-habit
  :group 'org-faces)
(defface org-habit-ready-future-face
  '((((background light)) (:background "#acfca9"))
    (((background dark)) (:background "dark green")))
  "Face for days on which a task should start to be done."
  :group 'org-habit
  :group 'org-faces)

(defface org-habit-alert-face
  '((((background light)) (:background "#f5f946"))
    (((background dark)) (:background "gold")))
  "Face for days on which a task is due."
  :group 'org-habit
  :group 'org-faces)
(defface org-habit-alert-future-face
  '((((background light)) (:background "#fafca9"))
    (((background dark)) (:background "dark goldenrod")))
  "Face for days on which a task is due."
  :group 'org-habit
  :group 'org-faces)

(defface org-habit-overdue-face
  '((((background light)) (:background "#f9372d"))
    (((background dark)) (:background "firebrick")))
  "Face for days on which a task is overdue."
  :group 'org-habit
  :group 'org-faces)
(defface org-habit-overdue-future-face
  '((((background light)) (:background "#fc9590"))
    (((background dark)) (:background "dark red")))
  "Face for days on which a task is overdue."
  :group 'org-habit
  :group 'org-faces)

(defvar org-habit-last-todo-change nil)
(defun org-habit-duration-to-days (ts)
  (if (string-match "\\([0-9]+\\)\\([dwmy]\\)" ts)
      ;; lead time is specified.
      (floor (* (string-to-number (match-string 1 ts))
                (cdr (assoc (match-string 2 ts)
                            '(("d" . 1)    ("w" . 7)
                              ("m" . 30.4) ("y" . 365.25))))))
    (error "Invalid duration string: %s" ts)))

(defun org-is-habit-p (&optional pom)
  "Is the task at POM or point a habit?"
  (string= "habit" (org-entry-get (or pom (point)) "STYLE")))


(defun org-habit-parse-todo (&optional pom)
  "Parse the TODO surrounding point for its habit-related data.
                  Returns a list with the following elements:

                    0: Scheduled date for the habit (may be in the past)
                    1: \".+\"-style repeater for the schedule, in days
                    2: Optional deadline (nil if not present)
                    3: If deadline, the repeater for the deadline, otherwise nil
                    4: A list of all the past dates this todo was mark closed
                    5: Repeater type as a string
                    6: Valid weekdays, all if ommited
                  This list represents a \"habit\" for the rest of this module."
  (save-excursion
    (if pom (goto-char pom))
    (assert (org-is-habit-p (point)))
    (let* ((scheduled (org-get-scheduled-time (point)))
           (scheduled-repeat (org-get-repeat))
           (end (org-entry-end-position))
           (habit-entry (org-no-properties (nth 4 (org-heading-components))))
           (w-days (org-habit-get-weekdays (org-entry-properties)))
           closed-dates deadline dr-days sr-days sr-type closed-dates-weekdays)
      (if scheduled
          (setq scheduled (cons (time-to-days scheduled) (org-habit--time-to-weekday scheduled)))
        (error "Habit %s has no scheduled date" habit-entry))
      (unless scheduled-repeat
        (error
         "Habit `%s' has no scheduled repeat period or has an incorrect one"
         habit-entry))
      (setq sr-days (org-habit-duration-to-days scheduled-repeat)
            sr-type (progn (string-match "[\\.+]?\\+" scheduled-repeat)
                           (org-match-string-no-properties 0 scheduled-repeat)))
      (unless (> sr-days 0)
        (error "Habit %s scheduled repeat period is less than 1d" habit-entry))
      (when (string-match "/\\([0-9]+[dwmy]\\)" scheduled-repeat)
        (setq dr-days (org-habit-duration-to-days
                       (match-string-no-properties 1 scheduled-repeat)))
        (if (<= dr-days sr-days)
            (error "Habit %s deadline repeat period is less than or equal to scheduled (%s)"
                   habit-entry scheduled-repeat))
        (setq deadline (org-habit--cons+ scheduled (- dr-days sr-days) w-days)))
      (org-back-to-heading t)
      (let* ((maxdays (+ org-habit-preceding-days org-habit-following-days))
             (reversed org-log-states-order-reversed)
             (search (if reversed 're-search-forward 're-search-backward))
             (limit (if reversed end (point)))
             (count 0)
             (re (format
                  "^[ \t]*-[ \t]+\\(?:State \"%s\".*%s%s\\)"
                  (regexp-opt org-done-keywords)
                  org-ts-regexp-inactive
                  (let ((value (cdr (assq 'done org-log-note-headings))))
                    (if (not value) ""
                      (concat "\\|"
                              (org-replace-escapes
                               (regexp-quote value)
                               `(("%d" . ,org-ts-regexp-inactive)
                                 ("%D" . ,org-ts-regexp)
                                 ("%s" . "\"\\S-+\"")
                                 ("%S" . "\"\\S-+\"")
                                 ("%t" . ,org-ts-regexp-inactive)
                                 ("%T" . ,org-ts-regexp)
                                 ("%u" . ".*?")
                                 ("%U" . ".*?")))))))))

        (while (and (< count maxdays) (funcall search re limit t))
          (let* ((tm (org-time-string-to-time
                      (or (org-match-string-no-properties 1)
                          (org-match-string-no-properties 2))))
                 (weekday (string-to-number (format-time-string "%u" tm)))
                 (time (time-to-days tm)))
            (push (cons time weekday) closed-dates-weekdays)
            (push time closed-dates))
          (setq count (1+ count))))
      (list scheduled sr-days deadline dr-days closed-dates sr-type w-days closed-dates-weekdays))))

(defsubst org-habit-get-weekdays (properties)
  (let ((weekdays (split-string (or (cdr (assoc "HABIT_WEEKDAYS" properties)) "1 2 3 4 5 6 7")))
        result)
    (dolist (day weekdays result)
      (push (string-to-number day) result))
    result))

(defsubst org-habit-scheduled (habit)
  (nth 0 habit))
(defsubst org-habit-scheduled-repeat (habit)
  (nth 1 habit))
(defsubst org-habit-deadline (habit)
  (let ((deadline (nth 2 habit)))
    (or deadline
        (if (nth 3 habit)
            (org-habit--cons+ (org-habit-scheduled habit)
                              (1- (org-habit-scheduled-repeat habit))
                              (org-habit-weekdays habit))
          (org-habit-scheduled habit)))))
(defsubst org-habit-deadline-repeat (habit)
  (or (nth 3 habit)
      (org-habit-scheduled-repeat habit)))
(defsubst org-habit-done-dates (habit)
  (nth 4 habit))
(defsubst org-habit-repeat-type (habit)
  (nth 5 habit))
(defsubst org-habit-weekdays (habit)
  (nth 6 habit))
(defsubst org-habit-done-dates-weekdays (habit)
  (nth 7 habit))

(defsubst org-habit-get-priority (habit &optional moment)
  "Determine the relative priority of a habit.
            This must take into account not just urgency, but consistency as well."
  (let ((pri 1000)
        (now (if moment (time-to-days moment) (org-today)))
        (scheduled (car (org-habit-scheduled habit)))
        (deadline (car (org-habit-deadline habit))))
    ;; add 10 for every day past the scheduled date, and subtract for every
    ;; day before it
    (setq pri (+ pri (* (- now scheduled) 10)))
    ;; add 50 if the deadline is today
    (if (and (/= scheduled deadline)
             (= now deadline))
        (setq pri (+ pri 50)))
    ;; add 100 for every day beyond the deadline date, and subtract 10 for
    ;; every day before it
    (let ((slip (- now (1- deadline))))
      (if (> slip 0)
          (setq pri (+ pri (* slip 100)))
        (setq pri (+ pri (* slip 10)))))
    pri))

(defun org-habit-get-faces (habit &optional now-days scheduled-days donep skip-p)
  "Return faces for HABIT relative to NOW-DAYS and SCHEDULED-DAYS.
                         NOW-DAYS defaults to the current time's days-past-the-epoch if nil.
                         SCHEDULED-DAYS defaults to the habit's actual scheduled days if nil.

                         Habits are assigned colors on the following basis:
                           Blue      Task is before the scheduled date.
                           Green     Task is on or after scheduled date, but before the
                               end of the schedule's repeat period.
                           Yellow    If the task has a deadline, then it is after schedule's
                               repeat period, but before the deadline.
                           Orange    The task has reached the deadline day, or if there is
                               no deadline, the end of the schedule's repeat period.
                           Red       The task has gone beyond the deadline day or the
                               schedule's repeat period."
  (let* ((scheduled (or scheduled-days (org-habit-scheduled habit)))
         (s-repeat (org-habit-scheduled-repeat habit))
         (w-days (org-habit-weekdays habit))
         ;;(scheduled-end (org-habit--cons+ scheduled (1- s-repeat)) w-days)
         (d-repeat (org-habit-deadline-repeat habit))
         ;; (deadline (org-habit-deadline habit))
         (deadline (if scheduled-days
                       (org-habit--cons+ scheduled (- d-repeat s-repeat) w-days)
                     (org-habit-deadline habit)))
         ;; (deadline (org-habit--cons+ scheduled (- d-repeat s-repeat) w-days))

         (m-days (or now-days (cons (time-to-days (current-time)) (org-habit--time-to-weekday (current-time))))))
    ;; (message "scheduled: %s deadline %s" scheduled deadline)
    (cond
     ((or skip-p (org-habit--car< m-days scheduled))
      (if (and (not scheduled-days) donep)
          '(org-habit-ready-face . org-habit-ready-future-face)
        '(org-habit-clear-face . org-habit-clear-future-face)))
     ((org-habit--car< m-days deadline)
      '(org-habit-ready-face . org-habit-ready-future-face))
     ((org-habit--car= m-days deadline)
      (if donep
          '(org-habit-ready-face . org-habit-ready-future-face)
        '(org-habit-alert-face . org-habit-alert-future-face)))
     ((and org-habit-show-done-always-green donep)
      '(org-habit-ready-face . org-habit-ready-future-face))
     (t '(org-habit-overdue-face . org-habit-overdue-future-face)))))

(defsubst org-habit--car= (arg1 arg2)
  "Like = but for CARs"
  (= (car arg1) (car arg2)))

(defsubst org-habit--car< (arg1 arg2)
  "Like < but for CARs"
  (< (car arg1) (car arg2)))

(defsubst org-habit--weekday-increment (wd inc)
  (let ((wd (+ wd inc)))
    (while (< wd 0)
      (setq wd (+ wd 7)))
    (setq wd (% wd 7))
    (if (= wd 0)
        (setq wd 7)
      wd)))

(defsubst org-habit--lacking-weekdays (wd inc w-days)
  (let ((i 0)
        (lack 0))
    (while (< i inc)
      (setq wd (org-habit--weekday-increment wd 1))
      (if (member wd w-days)
          (setq i (1+ i))
        (setq lack (1+ lack)
              i (1+ i))))
    lack))

(defsubst org-habit--cons+ (date inc w-days)
  (when (equal w-days 'all)
    (setq w-days '(1 2 3 4 5 6 7)))
  (let ((dt (+ (car date) inc))
        (wd (org-habit--weekday-increment (cdr date) inc))
        (lack (org-habit--lacking-weekdays (cdr date) inc w-days)))
    (while (< wd 0)
      (setq wd (+ wd 7)))
    (setq dt (+ dt lack)
          wd (org-habit--weekday-increment wd lack))
    (while (not (member wd w-days))
      (setq dt (1+ dt)
            wd (org-habit--weekday-increment wd 1)))
    (cons dt wd)))

(defsubst org-habit--time-to-weekday (time)
  (string-to-number (format-time-string "%u" time)))

(defun org-habit-build-graph (habit starting current ending)
  "Build a graph for the given HABIT, from STARTING to ENDING.
                           CURRENT gives the current time between STARTING and ENDING, for
                           the purpose of drawing the graph.  It need not be the actual
                           current time."
  (let* (;(done-dates (sort (org-habit-done-dates habit) '<))
         (done-dates (sort (org-habit-done-dates-weekdays habit) 'org-habit--car<))
         (w-days (org-habit-weekdays habit))
         (scheduled (org-habit-scheduled habit))
         (s-repeat (org-habit-scheduled-repeat habit))
         (weekday (org-habit--time-to-weekday starting))
         (start (cons (time-to-days starting) weekday))
         (now (time-to-days current))
         (end (time-to-days ending))
         (type (org-habit-repeat-type habit))
         (graph (make-string (1+ (- end (car start))) ?\ ))
         (index 0)
         ++start
         ++index
         base incr  ++incr
         mess
         last-done-date skip-p)
    (while (and done-dates (org-habit--car< (car done-dates) start))
      (setq last-done-date (car done-dates)
            done-dates (cdr done-dates)))
    (when (equal type "++")
      (if (and last-done-date (org-habit--car< start last-done-date))
          (setq ++start last-done-date)
        (setq ++start start)))
    (while (< (car start) end)
      (when (equal type "++")
        (setq incr (if (not incr)
                       (progn
                         (setq ++incr (if (= s-repeat 1)
                                          (+ 1 (- (car last-done-date) (car scheduled)))
                                        (* (+ 0 (/ (- (car ++start) (car scheduled)) s-repeat)) s-repeat))
                               ++index (- ++incr (- (car ++start) (car scheduled))))
                         ++incr)
                     incr)))
      (let* ((in-the-past-p (< (car start) now))
             (todayp (= (car start) now))
             (donep (and done-dates
                         (org-habit--car= start (car done-dates))))
             (skip-p (not (member (cdr start) w-days)))
             (faces (if (equal type "++")
                        (if (and in-the-past-p
                                 (not (car last-done-date)))
                            '(org-habit-clear-face . org-habit-clear-future-face)
                          (org-habit-get-faces
                           habit start
                           ;; Scheduled time was the first time
                           ;; past LAST-DONE-STATE which can jump
                           ;; to current SCHEDULED time by
                           ;; (S-REPEAT hops - 1).
                           ;; unfortunately this simple formula doesn't work in most cases
                           ;; i.e. it works when a habit is done on time
                           ;; but otherwise it produces a wrong decrement shifted by 1 S-REPEAT period into future or past:
                           ;; for a ++1w S-REPEAT it might give -35, -21, -14, -7, -7 instead of -35, -28, -21, -14, -7.
                           ;; At first glance, there must be corner-cases, which depending on the combination of S-REPEAT value, number
                           ;; of S-REPEATs, days overdue, etc., will lead to such shift.
                           ;; The trivial solution used here is to apply this formula only once - the first time it is being used - to calculate
                           ;; the "leftmost" shift and then update it by S-REPEAT every S-REPEAT steps.
                           (progn
                             (setq base scheduled)
                             (org-habit--cons+ base incr 'all))
                           donep skip-p))
                      (if (and in-the-past-p
                               (not (car last-done-date))
                               (not (< (car scheduled) now)))
                          '(org-habit-clear-face . org-habit-clear-future-face)
                        (org-habit-get-faces
                         habit start
                         (and in-the-past-p last-done-date
                              ;; Compute scheduled time for habit at the
                              ;; time START was current.
                              (cond
                               ((equal type ".+")
                                (setq base last-done-date
                                      incr s-repeat))
                               ((equal type "+")
                                ;; Since LAST-DONE-DATE, each done
                                ;; mark shifted scheduled date by
                                ;; S-REPEAT.
                                (setq base scheduled
                                      incr (- (* (length done-dates) s-repeat)))))
                              (org-habit--cons+ base incr w-days))
                         donep skip-p))))
             markedp face)
        (when (equal type "++")
          ;; (message "calculating")
          (setq ++incr (if (and ++index (= 0 (% (- index ++index) s-repeat)))
                           (+ ++incr s-repeat)
                         (if (= s-repeat 1)
                             (1+ ++incr)
                           ++incr)))
          (when donep (setq incr ++incr))
          ;; (setq mess (format "incr: %s ++incr: %s ++index: %s scheduled: %s start: %s" incr ++incr ++index scheduled start))
          ;; (message "%s index: %s done: %s last: %s in-the-past: %s" mess index donep last-done-date in-the-past-p)
          )
        (if donep
            (let ((done-time (time-add
                              starting
                              (days-to-time
                               (- (car start) (time-to-days starting))))))

              (aset graph index org-habit-completed-glyph)
              (setq markedp t)
              (put-text-property
               index (1+ index) 'help-echo
               (format-time-string (org-time-stamp-format) done-time) graph)
              (while (and done-dates
                          (org-habit--car= start (car done-dates)))
                (setq last-done-date (car done-dates)
                      done-dates (cdr done-dates))))
          (if todayp
              (aset graph index org-habit-today-glyph)))
        (setq face (if (or in-the-past-p todayp)
                       (car faces)
                     (cdr faces)))
        (if (and in-the-past-p
                 (not (eq face 'org-habit-overdue-face))
                 (not markedp))
            (setq face (cdr faces)))
        (put-text-property index (1+ index) 'face face graph))
      (setq start (org-habit--cons+ start 1 'all)
            index (1+ index)))
    graph))

(defun org-habit-insert-consistency-graphs (&optional line)
  "Insert consistency graph for any habitual tasks."
  (let ((inhibit-read-only t) l c
        (buffer-invisibility-spec '(org-link))
        (moment (time-subtract (current-time)
                               (list 0 (* 3600 org-extend-today-until) 0))))
    (save-excursion
      (goto-char (if line (point-at-bol) (point-min)))
      (while (not (eobp))
        (let ((habit (get-text-property (point) 'org-habit-p)))
          (when habit
            (move-to-column org-habit-graph-column t)
            (delete-char (min (+ 1 org-habit-preceding-days
                                 org-habit-following-days)
                              (- (line-end-position) (point))))
            (insert-before-markers
             (org-habit-build-graph
              habit
              (time-subtract moment (days-to-time org-habit-preceding-days))
              moment
              (time-add moment (days-to-time org-habit-following-days))))))
        (forward-line)))))

(defun org-habit-toggle-habits ()
  "Toggle display of habits in an agenda buffer."
  (interactive)
  (org-agenda-check-type t 'agenda)
  (setq org-habit-show-habits (not org-habit-show-habits))
  (org-agenda-redo)
  (org-agenda-set-mode-name)
  (message "Habits turned %s"
           (if org-habit-show-habits "on" "off")))

(org-defkey org-agenda-mode-map "K" 'org-habit-toggle-habits)

(defun org-habit-reschedule (&optional pom)
  "Reschedule habit on the allowed day"
  (save-excursion
    (if pom (goto-char pom))
    (let* ((w-days (org-habit-get-weekdays (org-entry-properties (point))))
           (wd (org-habit--time-to-weekday (org-get-scheduled-time (point))))
           (inc (org-habit-duration-to-days (org-get-repeat)))  ; scheduled repeater
           (norm-inc (org-habit--weekday-increment inc 0)) ; normalized repeat days (0..7)
           (lack (org-habit--lacking-weekdays wd inc w-days)))
      ;; Because the org-handled rescheduling actually happens after this function is executed via the hook,
      ;; we must adjust the date in advance
      (message "%s" (point))
      (message "%s %s %s %s" w-days wd norm-inc lack)
      ;; (setq wd (org-habit--weekday-increment wd norm-inc))
      (while (not (member wd w-days))
        (org-entry-put nil "SCHEDULED" "later")
        (setq wd (org-habit--weekday-increment wd 1))
        (message "%s %s %s %s" w-days wd norm-inc lack)
        )
      t)))

(defun org-habit-maybe-reschedule (trigger-plist)
  (when (org-is-habit-p)
    (let ((type (plist-get trigger-plist :type))
          (pos (plist-get trigger-plist :position))
          (from (plist-get trigger-plist :from))
          (to (plist-get trigger-plist :to)))
      (message "%s" trigger-plist)
      (when (equal type 'todo-state-change)
        (if (not org-habit-last-todo-change)
            (setq org-habit-last-todo-change trigger-plist)
          (message "%s" org-habit-last-todo-change)
          (when (and (member from org-not-done-keywords)
                     (member to org-done-keywords)
                     (equal type (plist-get org-habit-last-todo-change :type))
                     (equal pos (plist-get org-habit-last-todo-change :position))
                     (equal from (plist-get org-habit-last-todo-change :to))
                     (equal to (plist-get org-habit-last-todo-change :from))
                     )
            (message "reschedule %s" (org-habit-reschedule pos))
            (org-time-string-to-time "<2015-11-29 Sun .+2d/5d>")
            (setq org-habit-last-todo-change nil)
            )))
      (message "%s %s %s %s" type pos from to)
      )))

(add-hook 'org-trigger-hook 'org-habit-maybe-reschedule)

(provide 'org-habit-plus)

;;; org-habit-plus.el ends here
