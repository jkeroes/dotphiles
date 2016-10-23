#!/bin/sh
# Tcl ignores the next line -*- tcl -*- \
exec wish "$0" -- "$@"

# Copyright © 2005-2014 Paul Mackerras.  All rights reserved.
# This program is free software; it may be used, copied, modified
# and distributed under the terms of the GNU General Public Licence,
# either version 2, or (at your option) any later version.

package require Tk

proc hasworktree {} {
    return [expr {[exec git rev-parse --is-bare-repository] == "false" &&
		  [exec git rev-parse --is-inside-git-dir] == "false"}]
}

proc reponame {} {
    global gitdir
    set n [file normalize $gitdir]
    if {[string match "*/.git" $n]} {
	set n [string range $n 0 end-5]
    }
    return [file tail $n]
}

proc gitworktree {} {
    variable _gitworktree
    if {[info exists _gitworktree]} {
	return $_gitworktree
    }
    # v1.7.0 introduced --show-toplevel to return the canonical work-tree
    if {[catch {set _gitworktree [exec git rev-parse --show-toplevel]}]} {
        # try to set work tree from environment, core.worktree or use
        # cdup to obtain a relative path to the top of the worktree. If
        # run from the top, the ./ prefix ensures normalize expands pwd.
        if {[catch { set _gitworktree $env(GIT_WORK_TREE) }]} {
	    catch {set _gitworktree [exec git config --get core.worktree]}
	    if {$_gitworktree eq ""} {
		set _gitworktree [file normalize ./[exec git rev-parse --show-cdup]]
	    }
        }
    }
    return $_gitworktree
}

# A simple scheduler for compute-intensive stuff.
# The aim is to make sure that event handlers for GUI actions can
# run at least every 50-100 ms.  Unfortunately fileevent handlers are
# run before X event handlers, so reading from a fast source can
# make the GUI completely unresponsive.
proc run args {
    global isonrunq runq currunq

    set script $args
    if {[info exists isonrunq($script)]} return
    if {$runq eq {} && ![info exists currunq]} {
	after idle dorunq
    }
    lappend runq [list {} $script]
    set isonrunq($script) 1
}

proc filerun {fd script} {
    fileevent $fd readable [list filereadable $fd $script]
}

proc filereadable {fd script} {
    global runq currunq

    fileevent $fd readable {}
    if {$runq eq {} && ![info exists currunq]} {
	after idle dorunq
    }
    lappend runq [list $fd $script]
}

proc nukefile {fd} {
    global runq

    for {set i 0} {$i < [llength $runq]} {} {
	if {[lindex $runq $i 0] eq $fd} {
	    set runq [lreplace $runq $i $i]
	} else {
	    incr i
	}
    }
}

proc dorunq {} {
    global isonrunq runq currunq

    set tstart [clock clicks -milliseconds]
    set t0 $tstart
    while {[llength $runq] > 0} {
	set fd [lindex $runq 0 0]
	set script [lindex $runq 0 1]
	set currunq [lindex $runq 0]
	set runq [lrange $runq 1 end]
	set repeat [eval $script]
	unset currunq
	set t1 [clock clicks -milliseconds]
	set t [expr {$t1 - $t0}]
	if {$repeat ne {} && $repeat} {
	    if {$fd eq {} || $repeat == 2} {
		# script returns 1 if it wants to be readded
		# file readers return 2 if they could do more straight away
		lappend runq [list $fd $script]
	    } else {
		fileevent $fd readable [list filereadable $fd $script]
	    }
	} elseif {$fd eq {}} {
	    unset isonrunq($script)
	}
	set t0 $t1
	if {$t1 - $tstart >= 80} break
    }
    if {$runq ne {}} {
	after idle dorunq
    }
}

proc reg_instance {fd} {
    global commfd leftover loginstance

    set i [incr loginstance]
    set commfd($i) $fd
    set leftover($i) {}
    return $i
}

proc unmerged_files {files} {
    global nr_unmerged

    # find the list of unmerged files
    set mlist {}
    set nr_unmerged 0
    if {[catch {
	set fd [open "| git ls-files -u" r]
    } err]} {
	show_error {} . "[mc "Couldn't get list of unmerged files:"] $err"
	exit 1
    }
    while {[gets $fd line] >= 0} {
	set i [string first "\t" $line]
	if {$i < 0} continue
	set fname [string range $line [expr {$i+1}] end]
	if {[lsearch -exact $mlist $fname] >= 0} continue
	incr nr_unmerged
	if {$files eq {} || [path_filter $files $fname]} {
	    lappend mlist $fname
	}
    }
    catch {close $fd}
    return $mlist
}

proc parseviewargs {n arglist} {
    global vdatemode vmergeonly vflags vdflags vrevs vfiltered vorigargs env
    global vinlinediff
    global worddiff git_version

    set vdatemode($n) 0
    set vmergeonly($n) 0
    set vinlinediff($n) 0
    set glflags {}
    set diffargs {}
    set nextisval 0
    set revargs {}
    set origargs $arglist
    set allknown 1
    set filtered 0
    set i -1
    foreach arg $arglist {
	incr i
	if {$nextisval} {
	    lappend glflags $arg
	    set nextisval 0
	    continue
	}
	switch -glob -- $arg {
	    "-d" -
	    "--date-order" {
		set vdatemode($n) 1
		# remove from origargs in case we hit an unknown option
		set origargs [lreplace $origargs $i $i]
		incr i -1
	    }
	    "-[puabwcrRBMC]" -
	    "--no-renames" - "--full-index" - "--binary" - "--abbrev=*" -
	    "--find-copies-harder" - "-l*" - "--ext-diff" - "--no-ext-diff" -
	    "--src-prefix=*" - "--dst-prefix=*" - "--no-prefix" -
	    "-O*" - "--text" - "--full-diff" - "--ignore-space-at-eol" -
	    "--ignore-space-change" - "-U*" - "--unified=*" {
		# These request or affect diff output, which we don't want.
		# Some could be used to set our defaults for diff display.
		lappend diffargs $arg
	    }
	    "--raw" - "--patch-with-raw" - "--patch-with-stat" -
	    "--name-only" - "--name-status" - "--color" -
	    "--log-size" - "--pretty=*" - "--decorate" - "--abbrev-commit" -
	    "--cc" - "-z" - "--header" - "--parents" - "--boundary" -
	    "--no-color" - "-g" - "--walk-reflogs" - "--no-walk" -
	    "--timestamp" - "relative-date" - "--date=*" - "--stdin" -
	    "--objects" - "--objects-edge" - "--reverse" {
		# These cause our parsing of git log's output to fail, or else
		# they're options we want to set ourselves, so ignore them.
	    }
	    "--color-words*" - "--word-diff=color" {
		# These trigger a word diff in the console interface,
		# so help the user by enabling our own support
		if {[package vcompare $git_version "1.7.2"] >= 0} {
		    set worddiff [mc "Color words"]
		}
	    }
	    "--word-diff*" {
		if {[package vcompare $git_version "1.7.2"] >= 0} {
		    set worddiff [mc "Markup words"]
		}
	    }
	    "--stat=*" - "--numstat" - "--shortstat" - "--summary" -
	    "--check" - "--exit-code" - "--quiet" - "--topo-order" -
	    "--full-history" - "--dense" - "--sparse" -
	    "--follow" - "--left-right" - "--encoding=*" {
		# These are harmless, and some are even useful
		lappend glflags $arg
	    }
	    "--diff-filter=*" - "--no-merges" - "--unpacked" -
	    "--max-count=*" - "--skip=*" - "--since=*" - "--after=*" -
	    "--until=*" - "--before=*" - "--max-age=*" - "--min-age=*" -
	    "--author=*" - "--committer=*" - "--grep=*" - "-[iE]" -
	    "--remove-empty" - "--first-parent" - "--cherry-pick" -
	    "-S*" - "-G*" - "--pickaxe-all" - "--pickaxe-regex" -
	    "--simplify-by-decoration" {
		# These mean that we get a subset of the commits
		set filtered 1
		lappend glflags $arg
	    }
	    "-L*" {
		# Line-log with 'stuck' argument (unstuck form is
		# not supported)
		set filtered 1
		set vinlinediff($n) 1
		set allknown 0
		lappend glflags $arg
	    }
	    "-n" {
		# This appears to be the only one that has a value as a
		# separate word following it
		set filtered 1
		set nextisval 1
		lappend glflags $arg
	    }
	    "--not" - "--all" {
		lappend revargs $arg
	    }
	    "--merge" {
		set vmergeonly($n) 1
		# git rev-parse doesn't understand --merge
		lappend revargs --gitk-symmetric-diff-marker MERGE_HEAD...HEAD
	    }
	    "--no-replace-objects" {
		set env(GIT_NO_REPLACE_OBJECTS) "1"
	    }
	    "-*" {
		# Other flag arguments including -<n>
		if {[string is digit -strict [string range $arg 1 end]]} {
		    set filtered 1
		} else {
		    # a flag argument that we don't recognize;
		    # that means we can't optimize
		    set allknown 0
		}
		lappend glflags $arg
	    }
	    default {
		# Non-flag arguments specify commits or ranges of commits
		if {[string match "*...*" $arg]} {
		    lappend revargs --gitk-symmetric-diff-marker
		}
		lappend revargs $arg
	    }
	}
    }
    set vdflags($n) $diffargs
    set vflags($n) $glflags
    set vrevs($n) $revargs
    set vfiltered($n) $filtered
    set vorigargs($n) $origargs
    return $allknown
}

proc parseviewrevs {view revs} {
    global vposids vnegids

    if {$revs eq {}} {
	set revs HEAD
    } elseif {[lsearch -exact $revs --all] >= 0} {
	lappend revs HEAD
    }
    if {[catch {set ids [eval exec git rev-parse $revs]} err]} {
	# we get stdout followed by stderr in $err
	# for an unknown rev, git rev-parse echoes it and then errors out
	set errlines [split $err "\n"]
	set badrev {}
	for {set l 0} {$l < [llength $errlines]} {incr l} {
	    set line [lindex $errlines $l]
	    if {!([string length $line] == 40 && [string is xdigit $line])} {
		if {[string match "fatal:*" $line]} {
		    if {[string match "fatal: ambiguous argument*" $line]
			&& $badrev ne {}} {
			if {[llength $badrev] == 1} {
			    set err "unknown revision $badrev"
			} else {
			    set err "unknown revisions: [join $badrev ", "]"
			}
		    } else {
			set err [join [lrange $errlines $l end] "\n"]
		    }
		    break
		}
		lappend badrev $line
	    }
	}
	error_popup "[mc "Error parsing revisions:"] $err"
	return {}
    }
    set ret {}
    set pos {}
    set neg {}
    set sdm 0
    foreach id [split $ids "\n"] {
	if {$id eq "--gitk-symmetric-diff-marker"} {
	    set sdm 4
	} elseif {[string match "^*" $id]} {
	    if {$sdm != 1} {
		lappend ret $id
		if {$sdm == 3} {
		    set sdm 0
		}
	    }
	    lappend neg [string range $id 1 end]
	} else {
	    if {$sdm != 2} {
		lappend ret $id
	    } else {
		lset ret end $id...[lindex $ret end]
	    }
	    lappend pos $id
	}
	incr sdm -1
    }
    set vposids($view) $pos
    set vnegids($view) $neg
    return $ret
}

# Start off a git log process and arrange to read its output
proc start_rev_list {view} {
    global startmsecs commitidx viewcomplete curview
    global tclencoding
    global viewargs viewargscmd viewfiles vfilelimit
    global showlocalchanges
    global viewactive viewinstances vmergeonly
    global mainheadid viewmainheadid viewmainheadid_orig
    global vcanopt vflags vrevs vorigargs
    global show_notes

    set startmsecs [clock clicks -milliseconds]
    set commitidx($view) 0
    # these are set this way for the error exits
    set viewcomplete($view) 1
    set viewactive($view) 0
    varcinit $view

    set args $viewargs($view)
    if {$viewargscmd($view) ne {}} {
	if {[catch {
	    set str [exec sh -c $viewargscmd($view)]
	} err]} {
	    error_popup "[mc "Error executing --argscmd command:"] $err"
	    return 0
	}
	set args [concat $args [split $str "\n"]]
    }
    set vcanopt($view) [parseviewargs $view $args]

    set files $viewfiles($view)
    if {$vmergeonly($view)} {
	set files [unmerged_files $files]
	if {$files eq {}} {
	    global nr_unmerged
	    if {$nr_unmerged == 0} {
		error_popup [mc "No files selected: --merge specified but\
			     no files are unmerged."]
	    } else {
		error_popup [mc "No files selected: --merge specified but\
			     no unmerged files are within file limit."]
	    }
	    return 0
	}
    }
    set vfilelimit($view) $files

    if {$vcanopt($view)} {
	set revs [parseviewrevs $view $vrevs($view)]
	if {$revs eq {}} {
	    return 0
	}
	set args [concat $vflags($view) $revs]
    } else {
	set args $vorigargs($view)
    }

    if {[catch {
	set fd [open [concat | git log --no-color -z --pretty=raw $show_notes \
			--parents --boundary $args "--" $files] r]
    } err]} {
	error_popup "[mc "Error executing git log:"] $err"
	return 0
    }
    set i [reg_instance $fd]
    set viewinstances($view) [list $i]
    set viewmainheadid($view) $mainheadid
    set viewmainheadid_orig($view) $mainheadid
    if {$files ne {} && $mainheadid ne {}} {
	get_viewmainhead $view
    }
    if {$showlocalchanges && $viewmainheadid($view) ne {}} {
	interestedin $viewmainheadid($view) dodiffindex
    }
    fconfigure $fd -blocking 0 -translation lf -eofchar {}
    if {$tclencoding != {}} {
	fconfigure $fd -encoding $tclencoding
    }
    filerun $fd [list getcommitlines $fd $i $view 0]
    nowbusy $view [mc "Reading"]
    set viewcomplete($view) 0
    set viewactive($view) 1
    return 1
}

proc stop_instance {inst} {
    global commfd leftover

    set fd $commfd($inst)
    catch {
	set pid [pid $fd]

	if {$::tcl_platform(platform) eq {windows}} {
	    exec taskkill /pid $pid
	} else {
	    exec kill $pid
	}
    }
    catch {close $fd}
    nukefile $fd
    unset commfd($inst)
    unset leftover($inst)
}

proc stop_backends {} {
    global commfd

    foreach inst [array names commfd] {
	stop_instance $inst
    }
}

proc stop_rev_list {view} {
    global viewinstances

    foreach inst $viewinstances($view) {
	stop_instance $inst
    }
    set viewinstances($view) {}
}

proc reset_pending_select {selid} {
    global pending_select mainheadid selectheadid

    if {$selid ne {}} {
	set pending_select $selid
    } elseif {$selectheadid ne {}} {
	set pending_select $selectheadid
    } else {
	set pending_select $mainheadid
    }
}

proc getcommits {selid} {
    global canv curview need_redisplay viewactive

    initlayout
    if {[start_rev_list $curview]} {
	reset_pending_select $selid
	show_status [mc "Reading commits..."]
	set need_redisplay 1
    } else {
	show_status [mc "No commits selected"]
    }
}

proc updatecommits {} {
    global curview vcanopt vorigargs vfilelimit viewinstances
    global viewactive viewcomplete tclencoding
    global startmsecs showneartags showlocalchanges
    global mainheadid viewmainheadid viewmainheadid_orig pending_select
    global hasworktree
    global varcid vposids vnegids vflags vrevs
    global show_notes

    set hasworktree [hasworktree]
    rereadrefs
    set view $curview
    if {$mainheadid ne $viewmainheadid_orig($view)} {
	if {$showlocalchanges} {
	    dohidelocalchanges
	}
	set viewmainheadid($view) $mainheadid
	set viewmainheadid_orig($view) $mainheadid
	if {$vfilelimit($view) ne {}} {
	    get_viewmainhead $view
	}
    }
    if {$showlocalchanges} {
	doshowlocalchanges
    }
    if {$vcanopt($view)} {
	set oldpos $vposids($view)
	set oldneg $vnegids($view)
	set revs [parseviewrevs $view $vrevs($view)]
	if {$revs eq {}} {
	    return
	}
	# note: getting the delta when negative refs change is hard,
	# and could require multiple git log invocations, so in that
	# case we ask git log for all the commits (not just the delta)
	if {$oldneg eq $vnegids($view)} {
	    set newrevs {}
	    set npos 0
	    # take out positive refs that we asked for before or
	    # that we have already seen
	    foreach rev $revs {
		if {[string length $rev] == 40} {
		    if {[lsearch -exact $oldpos $rev] < 0
			&& ![info exists varcid($view,$rev)]} {
			lappend newrevs $rev
			incr npos
		    }
		} else {
		    lappend $newrevs $rev
		}
	    }
	    if {$npos == 0} return
	    set revs $newrevs
	    set vposids($view) [lsort -unique [concat $oldpos $vposids($view)]]
	}
	set args [concat $vflags($view) $revs --not $oldpos]
    } else {
	set args $vorigargs($view)
    }
    if {[catch {
	set fd [open [concat | git log --no-color -z --pretty=raw $show_notes \
			--parents --boundary $args "--" $vfilelimit($view)] r]
    } err]} {
	error_popup "[mc "Error executing git log:"] $err"
	return
    }
    if {$viewactive($view) == 0} {
	set startmsecs [clock clicks -milliseconds]
    }
    set i [reg_instance $fd]
    lappend viewinstances($view) $i
    fconfigure $fd -blocking 0 -translation lf -eofchar {}
    if {$tclencoding != {}} {
	fconfigure $fd -encoding $tclencoding
    }
    filerun $fd [list getcommitlines $fd $i $view 1]
    incr viewactive($view)
    set viewcomplete($view) 0
    reset_pending_select {}
    nowbusy $view [mc "Reading"]
    if {$showneartags} {
	getallcommits
    }
}

proc reloadcommits {} {
    global curview viewcomplete selectedline currentid thickerline
    global showneartags treediffs commitinterest cached_commitrow
    global targetid

    set selid {}
    if {$selectedline ne {}} {
	set selid $currentid
    }

    if {!$viewcomplete($curview)} {
	stop_rev_list $curview
    }
    resetvarcs $curview
    set selectedline {}
    catch {unset currentid}
    catch {unset thickerline}
    catch {unset treediffs}
    readrefs
    changedrefs
    if {$showneartags} {
	getallcommits
    }
    clear_display
    catch {unset commitinterest}
    catch {unset cached_commitrow}
    catch {unset targetid}
    setcanvscroll
    getcommits $selid
    return 0
}

# This makes a string representation of a positive integer which
# sorts as a string in numerical order
proc strrep {n} {
    if {$n < 16} {
	return [format "%x" $n]
    } elseif {$n < 256} {
	return [format "x%.2x" $n]
    } elseif {$n < 65536} {
	return [format "y%.4x" $n]
    }
    return [format "z%.8x" $n]
}

# Procedures used in reordering commits from git log (without
# --topo-order) into the order for display.

proc varcinit {view} {
    global varcstart vupptr vdownptr vleftptr vbackptr varctok varcrow
    global vtokmod varcmod vrowmod varcix vlastins

    set varcstart($view) {{}}
    set vupptr($view) {0}
    set vdownptr($view) {0}
    set vleftptr($view) {0}
    set vbackptr($view) {0}
    set varctok($view) {{}}
    set varcrow($view) {{}}
    set vtokmod($view) {}
    set varcmod($view) 0
    set vrowmod($view) 0
    set varcix($view) {{}}
    set vlastins($view) {0}
}

proc resetvarcs {view} {
    global varcid varccommits parents children vseedcount ordertok
    global vshortids

    foreach vid [array names varcid $view,*] {
	unset varcid($vid)
	unset children($vid)
	unset parents($vid)
    }
    foreach vid [array names vshortids $view,*] {
	unset vshortids($vid)
    }
    # some commits might have children but haven't been seen yet
    foreach vid [array names children $view,*] {
	unset children($vid)
    }
    foreach va [array names varccommits $view,*] {
	unset varccommits($va)
    }
    foreach vd [array names vseedcount $view,*] {
	unset vseedcount($vd)
    }
    catch {unset ordertok}
}

# returns a list of the commits with no children
proc seeds {v} {
    global vdownptr vleftptr varcstart

    set ret {}
    set a [lindex $vdownptr($v) 0]
    while {$a != 0} {
	lappend ret [lindex $varcstart($v) $a]
	set a [lindex $vleftptr($v) $a]
    }
    return $ret
}

proc newvarc {view id} {
    global varcid varctok parents children vdatemode
    global vupptr vdownptr vleftptr vbackptr varcrow varcix varcstart
    global commitdata commitinfo vseedcount varccommits vlastins

    set a [llength $varctok($view)]
    set vid $view,$id
    if {[llength $children($vid)] == 0 || $vdatemode($view)} {
	if {![info exists commitinfo($id)]} {
	    parsecommit $id $commitdata($id) 1
	}
	set cdate [lindex [lindex $commitinfo($id) 4] 0]
	if {![string is integer -strict $cdate]} {
	    set cdate 0
	}
	if {![info exists vseedcount($view,$cdate)]} {
	    set vseedcount($view,$cdate) -1
	}
	set c [incr vseedcount($view,$cdate)]
	set cdate [expr {$cdate ^ 0xffffffff}]
	set tok "s[strrep $cdate][strrep $c]"
    } else {
	set tok {}
    }
    set ka 0
    if {[llength $children($vid)] > 0} {
	set kid [lindex $children($vid) end]
	set k $varcid($view,$kid)
	if {[string compare [lindex $varctok($view) $k] $tok] > 0} {
	    set ki $kid
	    set ka $k
	    set tok [lindex $varctok($view) $k]
	}
    }
    if {$ka != 0} {
	set i [lsearch -exact $parents($view,$ki) $id]
	set j [expr {[llength $parents($view,$ki)] - 1 - $i}]
	append tok [strrep $j]
    }
    set c [lindex $vlastins($view) $ka]
    if {$c == 0 || [string compare $tok [lindex $varctok($view) $c]] < 0} {
	set c $ka
	set b [lindex $vdownptr($view) $ka]
    } else {
	set b [lindex $vleftptr($view) $c]
    }
    while {$b != 0 && [string compare $tok [lindex $varctok($view) $b]] >= 0} {
	set c $b
	set b [lindex $vleftptr($view) $c]
    }
    if {$c == $ka} {
	lset vdownptr($view) $ka $a
	lappend vbackptr($view) 0
    } else {
	lset vleftptr($view) $c $a
	lappend vbackptr($view) $c
    }
    lset vlastins($view) $ka $a
    lappend vupptr($view) $ka
    lappend vleftptr($view) $b
    if {$b != 0} {
	lset vbackptr($view) $b $a
    }
    lappend varctok($view) $tok
    lappend varcstart($view) $id
    lappend vdownptr($view) 0
    lappend varcrow($view) {}
    lappend varcix($view) {}
    set varccommits($view,$a) {}
    lappend vlastins($view) 0
    return $a
}

proc splitvarc {p v} {
    global varcid varcstart varccommits varctok vtokmod
    global vupptr vdownptr vleftptr vbackptr varcix varcrow vlastins

    set oa $varcid($v,$p)
    set otok [lindex $varctok($v) $oa]
    set ac $varccommits($v,$oa)
    set i [lsearch -exact $varccommits($v,$oa) $p]
    if {$i <= 0} return
    set na [llength $varctok($v)]
    # "%" sorts before "0"...
    set tok "$otok%[strrep $i]"
    lappend varctok($v) $tok
    lappend varcrow($v) {}
    lappend varcix($v) {}
    set varccommits($v,$oa) [lrange $ac 0 [expr {$i - 1}]]
    set varccommits($v,$na) [lrange $ac $i end]
    lappend varcstart($v) $p
    foreach id $varccommits($v,$na) {
	set varcid($v,$id) $na
    }
    lappend vdownptr($v) [lindex $vdownptr($v) $oa]
    lappend vlastins($v) [lindex $vlastins($v) $oa]
    lset vdownptr($v) $oa $na
    lset vlastins($v) $oa 0
    lappend vupptr($v) $oa
    lappend vleftptr($v) 0
    lappend vbackptr($v) 0
    for {set b [lindex $vdownptr($v) $na]} {$b != 0} {set b [lindex $vleftptr($v) $b]} {
	lset vupptr($v) $b $na
    }
    if {[string compare $otok $vtokmod($v)] <= 0} {
	modify_arc $v $oa
    }
}

proc renumbervarc {a v} {
    global parents children varctok varcstart varccommits
    global vupptr vdownptr vleftptr vbackptr vlastins varcid vtokmod vdatemode

    set t1 [clock clicks -milliseconds]
    set todo {}
    set isrelated($a) 1
    set kidchanged($a) 1
    set ntot 0
    while {$a != 0} {
	if {[info exists isrelated($a)]} {
	    lappend todo $a
	    set id [lindex $varccommits($v,$a) end]
	    foreach p $parents($v,$id) {
		if {[info exists varcid($v,$p)]} {
		    set isrelated($varcid($v,$p)) 1
		}
	    }
	}
	incr ntot
	set b [lindex $vdownptr($v) $a]
	if {$b == 0} {
	    while {$a != 0} {
		set b [lindex $vleftptr($v) $a]
		if {$b != 0} break
		set a [lindex $vupptr($v) $a]
	    }
	}
	set a $b
    }
    foreach a $todo {
	if {![info exists kidchanged($a)]} continue
	set id [lindex $varcstart($v) $a]
	if {[llength $children($v,$id)] > 1} {
	    set children($v,$id) [lsort -command [list vtokcmp $v] \
				      $children($v,$id)]
	}
	set oldtok [lindex $varctok($v) $a]
	if {!$vdatemode($v)} {
	    set tok {}
	} else {
	    set tok $oldtok
	}
	set ka 0
	set kid [last_real_child $v,$id]
	if {$kid ne {}} {
	    set k $varcid($v,$kid)
	    if {[string compare [lindex $varctok($v) $k] $tok] > 0} {
		set ki $kid
		set ka $k
		set tok [lindex $varctok($v) $k]
	    }
	}
	if {$ka != 0} {
	    set i [lsearch -exact $parents($v,$ki) $id]
	    set j [expr {[llength $parents($v,$ki)] - 1 - $i}]
	    append tok [strrep $j]
	}
	if {$tok eq $oldtok} {
	    continue
	}
	set id [lindex $varccommits($v,$a) end]
	foreach p $parents($v,$id) {
	    if {[info exists varcid($v,$p)]} {
		set kidchanged($varcid($v,$p)) 1
	    } else {
		set sortkids($p) 1
	    }
	}
	lset varctok($v) $a $tok
	set b [lindex $vupptr($v) $a]
	if {$b != $ka} {
	    if {[string compare [lindex $varctok($v) $ka] $vtokmod($v)] < 0} {
		modify_arc $v $ka
	    }
	    if {[string compare [lindex $varctok($v) $b] $vtokmod($v)] < 0} {
		modify_arc $v $b
	    }
	    set c [lindex $vbackptr($v) $a]
	    set d [lindex $vleftptr($v) $a]
	    if {$c == 0} {
		lset vdownptr($v) $b $d
	    } else {
		lset vleftptr($v) $c $d
	    }
	    if {$d != 0} {
		lset vbackptr($v) $d $c
	    }
	    if {[lindex $vlastins($v) $b] == $a} {
		lset vlastins($v) $b $c
	    }
	    lset vupptr($v) $a $ka
	    set c [lindex $vlastins($v) $ka]
	    if {$c == 0 || \
		    [string compare $tok [lindex $varctok($v) $c]] < 0} {
		set c $ka
		set b [lindex $vdownptr($v) $ka]
	    } else {
		set b [lindex $vleftptr($v) $c]
	    }
	    while {$b != 0 && \
		      [string compare $tok [lindex $varctok($v) $b]] >= 0} {
		set c $b
		set b [lindex $vleftptr($v) $c]
	    }
	    if {$c == $ka} {
 		lset vdownptr($v) $ka $a
		lset vbackptr($v) $a 0
	    } else {
		lset vleftptr($v) $c $a
		lset vbackptr($v) $a $c
	    }
	    lset vleftptr($v) $a $b
	    if {$b != 0} {
		lset vbackptr($v) $b $a
	    }
	    lset vlastins($v) $ka $a
	}
    }
    foreach id [array names sortkids] {
	if {[llength $children($v,$id)] > 1} {
	    set children($v,$id) [lsort -command [list vtokcmp $v] \
				      $children($v,$id)]
	}
    }
    set t2 [clock clicks -milliseconds]
    #puts "renumbervarc did [llength $todo] of $ntot arcs in [expr {$t2-$t1}]ms"
}

# Fix up the graph after we have found out that in view $v,
# $p (a commit that we have already seen) is actually the parent
# of the last commit in arc $a.
proc fix_reversal {p a v} {
    global varcid varcstart varctok vupptr

    set pa $varcid($v,$p)
    if {$p ne [lindex $varcstart($v) $pa]} {
	splitvarc $p $v
	set pa $varcid($v,$p)
    }
    # seeds always need to be renumbered
    if {[lindex $vupptr($v) $pa] == 0 ||
	[string compare [lindex $varctok($v) $a] \
	     [lindex $varctok($v) $pa]] > 0} {
	renumbervarc $pa $v
    }
}

proc insertrow {id p v} {
    global cmitlisted children parents varcid varctok vtokmod
    global varccommits ordertok commitidx numcommits curview
    global targetid targetrow vshortids

    readcommit $id
    set vid $v,$id
    set cmitlisted($vid) 1
    set children($vid) {}
    set parents($vid) [list $p]
    set a [newvarc $v $id]
    set varcid($vid) $a
    lappend vshortids($v,[string range $id 0 3]) $id
    if {[string compare [lindex $varctok($v) $a] $vtokmod($v)] < 0} {
	modify_arc $v $a
    }
    lappend varccommits($v,$a) $id
    set vp $v,$p
    if {[llength [lappend children($vp) $id]] > 1} {
	set children($vp) [lsort -command [list vtokcmp $v] $children($vp)]
	catch {unset ordertok}
    }
    fix_reversal $p $a $v
    incr commitidx($v)
    if {$v == $curview} {
	set numcommits $commitidx($v)
	setcanvscroll
	if {[info exists targetid]} {
	    if {![comes_before $targetid $p]} {
		incr targetrow
	    }
	}
    }
}

proc insertfakerow {id p} {
    global varcid varccommits parents children cmitlisted
    global commitidx varctok vtokmod targetid targetrow curview numcommits

    set v $curview
    set a $varcid($v,$p)
    set i [lsearch -exact $varccommits($v,$a) $p]
    if {$i < 0} {
	puts "oops: insertfakerow can't find [shortids $p] on arc $a"
	return
    }
    set children($v,$id) {}
    set parents($v,$id) [list $p]
    set varcid($v,$id) $a
    lappend children($v,$p) $id
    set cmitlisted($v,$id) 1
    set numcommits [incr commitidx($v)]
    # note we deliberately don't update varcstart($v) even if $i == 0
    set varccommits($v,$a) [linsert $varccommits($v,$a) $i $id]
    modify_arc $v $a $i
    if {[info exists targetid]} {
	if {![comes_before $targetid $p]} {
	    incr targetrow
	}
    }
    setcanvscroll
    drawvisible
}

proc removefakerow {id} {
    global varcid varccommits parents children commitidx
    global varctok vtokmod cmitlisted currentid selectedline
    global targetid curview numcommits

    set v $curview
    if {[llength $parents($v,$id)] != 1} {
	puts "oops: removefakerow [shortids $id] has [llength $parents($v,$id)] parents"
	return
    }
    set p [lindex $parents($v,$id) 0]
    set a $varcid($v,$id)
    set i [lsearch -exact $varccommits($v,$a) $id]
    if {$i < 0} {
	puts "oops: removefakerow can't find [shortids $id] on arc $a"
	return
    }
    unset varcid($v,$id)
    set varccommits($v,$a) [lreplace $varccommits($v,$a) $i $i]
    unset parents($v,$id)
    unset children($v,$id)
    unset cmitlisted($v,$id)
    set numcommits [incr commitidx($v) -1]
    set j [lsearch -exact $children($v,$p) $id]
    if {$j >= 0} {
	set children($v,$p) [lreplace $children($v,$p) $j $j]
    }
    modify_arc $v $a $i
    if {[info exist currentid] && $id eq $currentid} {
	unset currentid
	set selectedline {}
    }
    if {[info exists targetid] && $targetid eq $id} {
	set targetid $p
    }
    setcanvscroll
    drawvisible
}

proc real_children {vp} {
    global children nullid nullid2

    set kids {}
    foreach id $children($vp) {
	if {$id ne $nullid && $id ne $nullid2} {
	    lappend kids $id
	}
    }
    return $kids
}

proc first_real_child {vp} {
    global children nullid nullid2

    foreach id $children($vp) {
	if {$id ne $nullid && $id ne $nullid2} {
	    return $id
	}
    }
    return {}
}

proc last_real_child {vp} {
    global children nullid nullid2

    set kids $children($vp)
    for {set i [llength $kids]} {[incr i -1] >= 0} {} {
	set id [lindex $kids $i]
	if {$id ne $nullid && $id ne $nullid2} {
	    return $id
	}
    }
    return {}
}

proc vtokcmp {v a b} {
    global varctok varcid

    return [string compare [lindex $varctok($v) $varcid($v,$a)] \
		[lindex $varctok($v) $varcid($v,$b)]]
}

# This assumes that if lim is not given, the caller has checked that
# arc a's token is less than $vtokmod($v)
proc modify_arc {v a {lim {}}} {
    global varctok vtokmod varcmod varcrow vupptr curview vrowmod varccommits

    if {$lim ne {}} {
	set c [string compare [lindex $varctok($v) $a] $vtokmod($v)]
	if {$c > 0} return
	if {$c == 0} {
	    set r [lindex $varcrow($v) $a]
	    if {$r ne {} && $vrowmod($v) <= $r + $lim} return
	}
    }
    set vtokmod($v) [lindex $varctok($v) $a]
    set varcmod($v) $a
    if {$v == $curview} {
	while {$a != 0 && [lindex $varcrow($v) $a] eq {}} {
	    set a [lindex $vupptr($v) $a]
	    set lim {}
	}
	set r 0
	if {$a != 0} {
	    if {$lim eq {}} {
		set lim [llength $varccommits($v,$a)]
	    }
	    set r [expr {[lindex $varcrow($v) $a] + $lim}]
	}
	set vrowmod($v) $r
	undolayout $r
    }
}

proc update_arcrows {v} {
    global vtokmod varcmod vrowmod varcrow commitidx currentid selectedline
    global varcid vrownum varcorder varcix varccommits
    global vupptr vdownptr vleftptr varctok
    global displayorder parentlist curview cached_commitrow

    if {$vrowmod($v) == $commitidx($v)} return
    if {$v == $curview} {
	if {[llength $displayorder] > $vrowmod($v)} {
	    set displayorder [lrange $displayorder 0 [expr {$vrowmod($v) - 1}]]
	    set parentlist [lrange $parentlist 0 [expr {$vrowmod($v) - 1}]]
	}
	catch {unset cached_commitrow}
    }
    set narctot [expr {[llength $varctok($v)] - 1}]
    set a $varcmod($v)
    while {$a != 0 && [lindex $varcix($v) $a] eq {}} {
	# go up the tree until we find something that has a row number,
	# or we get to a seed
	set a [lindex $vupptr($v) $a]
    }
    if {$a == 0} {
	set a [lindex $vdownptr($v) 0]
	if {$a == 0} return
	set vrownum($v) {0}
	set varcorder($v) [list $a]
	lset varcix($v) $a 0
	lset varcrow($v) $a 0
	set arcn 0
	set row 0
    } else {
	set arcn [lindex $varcix($v) $a]
	if {[llength $vrownum($v)] > $arcn + 1} {
	    set vrownum($v) [lrange $vrownum($v) 0 $arcn]
	    set varcorder($v) [lrange $varcorder($v) 0 $arcn]
	}
	set row [lindex $varcrow($v) $a]
    }
    while {1} {
	set p $a
	incr row [llength $varccommits($v,$a)]
	# go down if possible
	set b [lindex $vdownptr($v) $a]
	if {$b == 0} {
	    # if not, go left, or go up until we can go left
	    while {$a != 0} {
		set b [lindex $vleftptr($v) $a]
		if {$b != 0} break
		set a [lindex $vupptr($v) $a]
	    }
	    if {$a == 0} break
	}
	set a $b
	incr arcn
	lappend vrownum($v) $row
	lappend varcorder($v) $a
	lset varcix($v) $a $arcn
	lset varcrow($v) $a $row
    }
    set vtokmod($v) [lindex $varctok($v) $p]
    set varcmod($v) $p
    set vrowmod($v) $row
    if {[info exists currentid]} {
	set selectedline [rowofcommit $currentid]
    }
}

# Test whether view $v contains commit $id
proc commitinview {id v} {
    global varcid

    return [info exists varcid($v,$id)]
}

# Return the row number for commit $id in the current view
proc rowofcommit {id} {
    global varcid varccommits varcrow curview cached_commitrow
    global varctok vtokmod

    set v $curview
    if {![info exists varcid($v,$id)]} {
	puts "oops rowofcommit no arc for [shortids $id]"
	return {}
    }
    set a $varcid($v,$id)
    if {[string compare [lindex $varctok($v) $a] $vtokmod($v)] >= 0} {
	update_arcrows $v
    }
    if {[info exists cached_commitrow($id)]} {
	return $cached_commitrow($id)
    }
    set i [lsearch -exact $varccommits($v,$a) $id]
    if {$i < 0} {
	puts "oops didn't find commit [shortids $id] in arc $a"
	return {}
    }
    incr i [lindex $varcrow($v) $a]
    set cached_commitrow($id) $i
    return $i
}

# Returns 1 if a is on an earlier row than b, otherwise 0
proc comes_before {a b} {
    global varcid varctok curview

    set v $curview
    if {$a eq $b || ![info exists varcid($v,$a)] || \
	    ![info exists varcid($v,$b)]} {
	return 0
    }
    if {$varcid($v,$a) != $varcid($v,$b)} {
	return [expr {[string compare [lindex $varctok($v) $varcid($v,$a)] \
			   [lindex $varctok($v) $varcid($v,$b)]] < 0}]
    }
    return [expr {[rowofcommit $a] < [rowofcommit $b]}]
}

proc bsearch {l elt} {
    if {[llength $l] == 0 || $elt <= [lindex $l 0]} {
	return 0
    }
    set lo 0
    set hi [llength $l]
    while {$hi - $lo > 1} {
	set mid [expr {int(($lo + $hi) / 2)}]
	set t [lindex $l $mid]
	if {$elt < $t} {
	    set hi $mid
	} elseif {$elt > $t} {
	    set lo $mid
	} else {
	    return $mid
	}
    }
    return $lo
}

# Make sure rows $start..$end-1 are valid in displayorder and parentlist
proc make_disporder {start end} {
    global vrownum curview commitidx displayorder parentlist
    global varccommits varcorder parents vrowmod varcrow
    global d_valid_start d_valid_end

    if {$end > $vrowmod($curview)} {
	update_arcrows $curview
    }
    set ai [bsearch $vrownum($curview) $start]
    set start [lindex $vrownum($curview) $ai]
    set narc [llength $vrownum($curview)]
    for {set r $start} {$ai < $narc && $r < $end} {incr ai} {
	set a [lindex $varcorder($curview) $ai]
	set l [llength $displayorder]
	set al [llength $varccommits($curview,$a)]
	if {$l < $r + $al} {
	    if {$l < $r} {
		set pad [ntimes [expr {$r - $l}] {}]
		set displayorder [concat $displayorder $pad]
		set parentlist [concat $parentlist $pad]
	    } elseif {$l > $r} {
		set displayorder [lrange $displayorder 0 [expr {$r - 1}]]
		set parentlist [lrange $parentlist 0 [expr {$r - 1}]]
	    }
	    foreach id $varccommits($curview,$a) {
		lappend displayorder $id
		lappend parentlist $parents($curview,$id)
	    }
	} elseif {[lindex $displayorder [expr {$r + $al - 1}]] eq {}} {
	    set i $r
	    foreach id $varccommits($curview,$a) {
		lset displayorder $i $id
		lset parentlist $i $parents($curview,$id)
		incr i
	    }
	}
	incr r $al
    }
}

proc commitonrow {row} {
    global displayorder

    set id [lindex $displayorder $row]
    if {$id eq {}} {
	make_disporder $row [expr {$row + 1}]
	set id [lindex $displayorder $row]
    }
    return $id
}

proc closevarcs {v} {
    global varctok varccommits varcid parents children
    global cmitlisted commitidx vtokmod

    set missing_parents 0
    set scripts {}
    set narcs [llength $varctok($v)]
    for {set a 1} {$a < $narcs} {incr a} {
	set id [lindex $varccommits($v,$a) end]
	foreach p $parents($v,$id) {
	    if {[info exists varcid($v,$p)]} continue
	    # add p as a new commit
	    incr missing_parents
	    set cmitlisted($v,$p) 0
	    set parents($v,$p) {}
	    if {[llength $children($v,$p)] == 1 &&
		[llength $parents($v,$id)] == 1} {
		set b $a
	    } else {
		set b [newvarc $v $p]
	    }
	    set varcid($v,$p) $b
	    if {[string compare [lindex $varctok($v) $b] $vtokmod($v)] < 0} {
		modify_arc $v $b
	    }
	    lappend varccommits($v,$b) $p
	    incr commitidx($v)
	    set scripts [check_interest $p $scripts]
	}
    }
    if {$missing_parents > 0} {
	foreach s $scripts {
	    eval $s
	}
    }
}

# Use $rwid as a substitute for $id, i.e. reparent $id's children to $rwid
# Assumes we already have an arc for $rwid.
proc rewrite_commit {v id rwid} {
    global children parents varcid varctok vtokmod varccommits

    foreach ch $children($v,$id) {
	# make $rwid be $ch's parent in place of $id
	set i [lsearch -exact $parents($v,$ch) $id]
	if {$i < 0} {
	    puts "oops rewrite_commit didn't find $id in parent list for $ch"
	}
	set parents($v,$ch) [lreplace $parents($v,$ch) $i $i $rwid]
	# add $ch to $rwid's children and sort the list if necessary
	if {[llength [lappend children($v,$rwid) $ch]] > 1} {
	    set children($v,$rwid) [lsort -command [list vtokcmp $v] \
					$children($v,$rwid)]
	}
	# fix the graph after joining $id to $rwid
	set a $varcid($v,$ch)
	fix_reversal $rwid $a $v
	# parentlist is wrong for the last element of arc $a
	# even if displayorder is right, hence the 3rd arg here
	modify_arc $v $a [expr {[llength $varccommits($v,$a)] - 1}]
    }
}

# Mechanism for registering a command to be executed when we come
# across a particular commit.  To handle the case when only the
# prefix of the commit is known, the commitinterest array is now
# indexed by the first 4 characters of the ID.  Each element is a
# list of id, cmd pairs.
proc interestedin {id cmd} {
    global commitinterest

    lappend commitinterest([string range $id 0 3]) $id $cmd
}

proc check_interest {id scripts} {
    global commitinterest

    set prefix [string range $id 0 3]
    if {[info exists commitinterest($prefix)]} {
	set newlist {}
	foreach {i script} $commitinterest($prefix) {
	    if {[string match "$i*" $id]} {
		lappend scripts [string map [list "%I" $id "%P" $i] $script]
	    } else {
		lappend newlist $i $script
	    }
	}
	if {$newlist ne {}} {
	    set commitinterest($prefix) $newlist
	} else {
	    unset commitinterest($prefix)
	}
    }
    return $scripts
}

proc getcommitlines {fd inst view updating}  {
    global cmitlisted leftover
    global commitidx commitdata vdatemode
    global parents children curview hlview
    global idpending ordertok
    global varccommits varcid varctok vtokmod vfilelimit vshortids

    set stuff [read $fd 500000]
    # git log doesn't terminate the last commit with a null...
    if {$stuff == {} && $leftover($inst) ne {} && [eof $fd]} {
	set stuff "\0"
    }
    if {$stuff == {}} {
	if {![eof $fd]} {
	    return 1
	}
	global commfd viewcomplete viewactive viewname
	global viewinstances
	unset commfd($inst)
	set i [lsearch -exact $viewinstances($view) $inst]
	if {$i >= 0} {
	    set viewinstances($view) [lreplace $viewinstances($view) $i $i]
	}
	# set it blocking so we wait for the process to terminate
	fconfigure $fd -blocking 1
	if {[catch {close $fd} err]} {
	    set fv {}
	    if {$view != $curview} {
		set fv " for the \"$viewname($view)\" view"
	    }
	    if {[string range $err 0 4] == "usage"} {
		set err "Gitk: error reading commits$fv:\
			bad arguments to git log."
		if {$viewname($view) eq "Command line"} {
		    append err \
			"  (Note: arguments to gitk are passed to git log\
			 to allow selection of commits to be displayed.)"
		}
	    } else {
		set err "Error reading commits$fv: $err"
	    }
	    error_popup $err
	}
	if {[incr viewactive($view) -1] <= 0} {
	    set viewcomplete($view) 1
	    # Check if we have seen any ids listed as parents that haven't
	    # appeared in the list
	    closevarcs $view
	    notbusy $view
	}
	if {$view == $curview} {
	    run chewcommits
	}
	return 0
    }
    set start 0
    set gotsome 0
    set scripts {}
    while 1 {
	set i [string first "\0" $stuff $start]
	if {$i < 0} {
	    append leftover($inst) [string range $stuff $start end]
	    break
	}
	if {$start == 0} {
	    set cmit $leftover($inst)
	    append cmit [string range $stuff 0 [expr {$i - 1}]]
	    set leftover($inst) {}
	} else {
	    set cmit [string range $stuff $start [expr {$i - 1}]]
	}
	set start [expr {$i + 1}]
	set j [string first "\n" $cmit]
	set ok 0
	set listed 1
	if {$j >= 0 && [string match "commit *" $cmit]} {
	    set ids [string range $cmit 7 [expr {$j - 1}]]
	    if {[string match {[-^<>]*} $ids]} {
		switch -- [string index $ids 0] {
		    "-" {set listed 0}
		    "^" {set listed 2}
		    "<" {set listed 3}
		    ">" {set listed 4}
		}
		set ids [string range $ids 1 end]
	    }
	    set ok 1
	    foreach id $ids {
		if {[string length $id] != 40} {
		    set ok 0
		    break
		}
	    }
	}
	if {!$ok} {
	    set shortcmit $cmit
	    if {[string length $shortcmit] > 80} {
		set shortcmit "[string range $shortcmit 0 80]..."
	    }
	    error_popup "[mc "Can't parse git log output:"] {$shortcmit}"
	    exit 1
	}
	set id [lindex $ids 0]
	set vid $view,$id

	lappend vshortids($view,[string range $id 0 3]) $id

	if {!$listed && $updating && ![info exists varcid($vid)] &&
	    $vfilelimit($view) ne {}} {
	    # git log doesn't rewrite parents for unlisted commits
	    # when doing path limiting, so work around that here
	    # by working out the rewritten parent with git rev-list
	    # and if we already know about it, using the rewritten
	    # parent as a substitute parent for $id's children.
	    if {![catch {
		set rwid [exec git rev-list --first-parent --max-count=1 \
			      $id -- $vfilelimit($view)]
	    }]} {
		if {$rwid ne {} && [info exists varcid($view,$rwid)]} {
		    # use $rwid in place of $id
		    rewrite_commit $view $id $rwid
		    continue
		}
	    }
	}

	set a 0
	if {[info exists varcid($vid)]} {
	    if {$cmitlisted($vid) || !$listed} continue
	    set a $varcid($vid)
	}
	if {$listed} {
	    set olds [lrange $ids 1 end]
	} else {
	    set olds {}
	}
	set commitdata($id) [string range $cmit [expr {$j + 1}] end]
	set cmitlisted($vid) $listed
	set parents($vid) $olds
	if {![info exists children($vid)]} {
	    set children($vid) {}
	} elseif {$a == 0 && [llength $children($vid)] == 1} {
	    set k [lindex $children($vid) 0]
	    if {[llength $parents($view,$k)] == 1 &&
		(!$vdatemode($view) ||
		 $varcid($view,$k) == [llength $varctok($view)] - 1)} {
		set a $varcid($view,$k)
	    }
	}
	if {$a == 0} {
	    # new arc
	    set a [newvarc $view $id]
	}
	if {[string compare [lindex $varctok($view) $a] $vtokmod($view)] < 0} {
	    modify_arc $view $a
	}
	if {![info exists varcid($vid)]} {
	    set varcid($vid) $a
	    lappend varccommits($view,$a) $id
	    incr commitidx($view)
	}

	set i 0
	foreach p $olds {
	    if {$i == 0 || [lsearch -exact $olds $p] >= $i} {
		set vp $view,$p
		if {[llength [lappend children($vp) $id]] > 1 &&
		    [vtokcmp $view [lindex $children($vp) end-1] $id] > 0} {
		    set children($vp) [lsort -command [list vtokcmp $view] \
					   $children($vp)]
		    catch {unset ordertok}
		}
		if {[info exists varcid($view,$p)]} {
		    fix_reversal $p $a $view
		}
	    }
	    incr i
	}

	set scripts [check_interest $id $scripts]
	set gotsome 1
    }
    if {$gotsome} {
	global numcommits hlview

	if {$view == $curview} {
	    set numcommits $commitidx($view)
	    run chewcommits
	}
	if {[info exists hlview] && $view == $hlview} {
	    # we never actually get here...
	    run vhighlightmore
	}
	foreach s $scripts {
	    eval $s
	}
    }
    return 2
}

proc chewcommits {} {
    global curview hlview viewcomplete
    global pending_select

    layoutmore
    if {$viewcomplete($curview)} {
	global commitidx varctok
	global numcommits startmsecs

	if {[info exists pending_select]} {
	    update
	    reset_pending_select {}

	    if {[commitinview $pending_select $curview]} {
		selectline [rowofcommit $pending_select] 1
	    } else {
		set row [first_real_row]
		selectline $row 1
	    }
	}
	if {$commitidx($curview) > 0} {
	    #set ms [expr {[clock clicks -milliseconds] - $startmsecs}]
	    #puts "overall $ms ms for $numcommits commits"
	    #puts "[llength $varctok($view)] arcs, $commitidx($view) commits"
	} else {
	    show_status [mc "No commits selected"]
	}
	notbusy layout
    }
    return 0
}

proc do_readcommit {id} {
    global tclencoding

    # Invoke git-log to handle automatic encoding conversion
    set fd [open [concat | git log --no-color --pretty=raw -1 $id] r]
    # Read the results using i18n.logoutputencoding
    fconfigure $fd -translation lf -eofchar {}
    if {$tclencoding != {}} {
	fconfigure $fd -encoding $tclencoding
    }
    set contents [read $fd]
    close $fd
    # Remove the heading line
    regsub {^commit [0-9a-f]+\n} $contents {} contents

    return $contents
}

proc readcommit {id} {
    if {[catch {set contents [do_readcommit $id]}]} return
    parsecommit $id $contents 1
}

proc parsecommit {id contents listed} {
    global commitinfo

    set inhdr 1
    set comment {}
    set headline {}
    set auname {}
    set audate {}
    set comname {}
    set comdate {}
    set hdrend [string first "\n\n" $contents]
    if {$hdrend < 0} {
	# should never happen...
	set hdrend [string length $contents]
    }
    set header [string range $contents 0 [expr {$hdrend - 1}]]
    set comment [string range $contents [expr {$hdrend + 2}] end]
    foreach line [split $header "\n"] {
	set line [split $line " "]
	set tag [lindex $line 0]
	if {$tag == "author"} {
	    set audate [lrange $line end-1 end]
	    set auname [join [lrange $line 1 end-2] " "]
	} elseif {$tag == "committer"} {
	    set comdate [lrange $line end-1 end]
	    set comname [join [lrange $line 1 end-2] " "]
	}
    }
    set headline {}
    # take the first non-blank line of the comment as the headline
    set headline [string trimleft $comment]
    set i [string first "\n" $headline]
    if {$i >= 0} {
	set headline [string range $headline 0 $i]
    }
    set headline [string trimright $headline]
    set i [string first "\r" $headline]
    if {$i >= 0} {
	set headline [string trimright [string range $headline 0 $i]]
    }
    if {!$listed} {
	# git log indents the comment by 4 spaces;
	# if we got this via git cat-file, add the indentation
	set newcomment {}
	foreach line [split $comment "\n"] {
	    append newcomment "    "
	    append newcomment $line
	    append newcomment "\n"
	}
	set comment $newcomment
    }
    set hasnote [string first "\nNotes:\n" $contents]
    set diff ""
    # If there is diff output shown in the git-log stream, split it
    # out.  But get rid of the empty line that always precedes the
    # diff.
    set i [string first "\n\ndiff" $comment]
    if {$i >= 0} {
	set diff [string range $comment $i+1 end]
	set comment [string range $comment 0 $i-1]
    }
    set commitinfo($id) [list $headline $auname $audate \
			     $comname $comdate $comment $hasnote $diff]
}

proc getcommit {id} {
    global commitdata commitinfo

    if {[info exists commitdata($id)]} {
	parsecommit $id $commitdata($id) 1
    } else {
	readcommit $id
	if {![info exists commitinfo($id)]} {
	    set commitinfo($id) [list [mc "No commit information available"]]
	}
    }
    return 1
}

# Expand an abbreviated commit ID to a list of full 40-char IDs that match
# and are present in the current view.
# This is fairly slow...
proc longid {prefix} {
    global varcid curview vshortids

    set ids {}
    if {[string length $prefix] >= 4} {
	set vshortid $curview,[string range $prefix 0 3]
	if {[info exists vshortids($vshortid)]} {
	    foreach id $vshortids($vshortid) {
		if {[string match "$prefix*" $id]} {
		    if {[lsearch -exact $ids $id] < 0} {
			lappend ids $id
			if {[llength $ids] >= 2} break
		    }
		}
	    }
	}
    } else {
	foreach match [array names varcid "$curview,$prefix*"] {
	    lappend ids [lindex [split $match ","] 1]
	    if {[llength $ids] >= 2} break
	}
    }
    return $ids
}

proc readrefs {} {
    global tagids idtags headids idheads tagobjid
    global otherrefids idotherrefs mainhead mainheadid
    global selecthead selectheadid
    global hideremotes

    foreach v {tagids idtags headids idheads otherrefids idotherrefs} {
	catch {unset $v}
    }
    set refd [open [list | git show-ref -d] r]
    while {[gets $refd line] >= 0} {
	if {[string index $line 40] ne " "} continue
	set id [string range $line 0 39]
	set ref [string range $line 41 end]
	if {![string match "refs/*" $ref]} continue
	set name [string range $ref 5 end]
	if {[string match "remotes/*" $name]} {
	    if {![string match "*/HEAD" $name] && !$hideremotes} {
		set headids($name) $id
		lappend idheads($id) $name
	    }
	} elseif {[string match "heads/*" $name]} {
	    set name [string range $name 6 end]
	    set headids($name) $id
	    lappend idheads($id) $name
	} elseif {[string match "tags/*" $name]} {
	    # this lets refs/tags/foo^{} overwrite refs/tags/foo,
	    # which is what we want since the former is the commit ID
	    set name [string range $name 5 end]
	    if {[string match "*^{}" $name]} {
		set name [string range $name 0 end-3]
	    } else {
		set tagobjid($name) $id
	    }
	    set tagids($name) $id
	    lappend idtags($id) $name
	} else {
	    set otherrefids($name) $id
	    lappend idotherrefs($id) $name
	}
    }
    catch {close $refd}
    set mainhead {}
    set mainheadid {}
    catch {
	set mainheadid [exec git rev-parse HEAD]
	set thehead [exec git symbolic-ref HEAD]
	if {[string match "refs/heads/*" $thehead]} {
	    set mainhead [string range $thehead 11 end]
	}
    }
    set selectheadid {}
    if {$selecthead ne {}} {
	catch {
	    set selectheadid [exec git rev-parse --verify $selecthead]
	}
    }
}

# skip over fake commits
proc first_real_row {} {
    global nullid nullid2 numcommits

    for {set row 0} {$row < $numcommits} {incr row} {
	set id [commitonrow $row]
	if {$id ne $nullid && $id ne $nullid2} {
	    break
	}
    }
    return $row
}

# update things for a head moved to a child of its previous location
proc movehead {id name} {
    global headids idheads

    removehead $headids($name) $name
    set headids($name) $id
    lappend idheads($id) $name
}

# update things when a head has been removed
proc removehead {id name} {
    global headids idheads

    if {$idheads($id) eq $name} {
	unset idheads($id)
    } else {
	set i [lsearch -exact $idheads($id) $name]
	if {$i >= 0} {
	    set idheads($id) [lreplace $idheads($id) $i $i]
	}
    }
    unset headids($name)
}

proc ttk_toplevel {w args} {
    global use_ttk
    eval [linsert $args 0 ::toplevel $w]
    if {$use_ttk} {
        place [ttk::frame $w._toplevel_background] -x 0 -y 0 -relwidth 1 -relheight 1
    }
    return $w
}

proc make_transient {window origin} {
    global have_tk85

    # In MacOS Tk 8.4 transient appears to work by setting
    # overrideredirect, which is utterly useless, since the
    # windows get no border, and are not even kept above
    # the parent.
    if {!$have_tk85 && [tk windowingsystem] eq {aqua}} return

    wm transient $window $origin

    # Windows fails to place transient windows normally, so
    # schedule a callback to center them on the parent.
    if {[tk windowingsystem] eq {win32}} {
	after idle [list tk::PlaceWindow $window widget $origin]
    }
}

proc show_error {w top msg {mc mc}} {
    global NS
    if {![info exists NS]} {set NS ""}
    if {[wm state $top] eq "withdrawn"} { wm deiconify $top }
    message $w.m -text $msg -justify center -aspect 400
    pack $w.m -side top -fill x -padx 20 -pady 20
    ${NS}::button $w.ok -default active -text [$mc OK] -command "destroy $top"
    pack $w.ok -side bottom -fill x
    bind $top <Visibility> "grab $top; focus $top"
    bind $top <Key-Return> "destroy $top"
    bind $top <Key-space>  "destroy $top"
    bind $top <Key-Escape> "destroy $top"
    tkwait window $top
}

proc error_popup {msg {owner .}} {
    if {[tk windowingsystem] eq "win32"} {
        tk_messageBox -icon error -type ok -title [wm title .] \
            -parent $owner -message $msg
    } else {
        set w .error
        ttk_toplevel $w
        make_transient $w $owner
        show_error $w $w $msg
    }
}

proc confirm_popup {msg {owner .}} {
    global confirm_ok NS
    set confirm_ok 0
    set w .confirm
    ttk_toplevel $w
    make_transient $w $owner
    message $w.m -text $msg -justify center -aspect 400
    pack $w.m -side top -fill x -padx 20 -pady 20
    ${NS}::button $w.ok -text [mc OK] -command "set confirm_ok 1; destroy $w"
    pack $w.ok -side left -fill x
    ${NS}::button $w.cancel -text [mc Cancel] -command "destroy $w"
    pack $w.cancel -side right -fill x
    bind $w <Visibility> "grab $w; focus $w"
    bind $w <Key-Return> "set confirm_ok 1; destroy $w"
    bind $w <Key-space>  "set confirm_ok 1; destroy $w"
    bind $w <Key-Escape> "destroy $w"
    tk::PlaceWindow $w widget $owner
    tkwait window $w
    return $confirm_ok
}

proc setoptions {} {
    if {[tk windowingsystem] ne "win32"} {
        option add *Panedwindow.showHandle 1 startupFile
        option add *Panedwindow.sashRelief raised startupFile
        if {[tk windowingsystem] ne "aqua"} {
            option add *Menu.font uifont startupFile
        }
    } else {
        option add *Menu.TearOff 0 startupFile
    }
    option add *Button.font uifont startupFile
    option add *Checkbutton.font uifont startupFile
    option add *Radiobutton.font uifont startupFile
    option add *Menubutton.font uifont startupFile
    option add *Label.font uifont startupFile
    option add *Message.font uifont startupFile
    option add *Entry.font textfont startupFile
    option add *Text.font textfont startupFile
    option add *Labelframe.font uifont startupFile
    option add *Spinbox.font textfont startupFile
    option add *Listbox.font mainfont startupFile
}

# Make a menu and submenus.
# m is the window name for the menu, items is the list of menu items to add.
# Each item is a list {mc label type description options...}
# mc is ignored; it's so we can put mc there to alert xgettext
# label is the string that appears in the menu
# type is cascade, command or radiobutton (should add checkbutton)
# description depends on type; it's the sublist for cascade, the
# command to invoke for command, or {variable value} for radiobutton
proc makemenu {m items} {
    menu $m
    if {[tk windowingsystem] eq {aqua}} {
	set Meta1 Cmd
    } else {
	set Meta1 Ctrl
    }
    foreach i $items {
	set name [mc [lindex $i 1]]
	set type [lindex $i 2]
	set thing [lindex $i 3]
	set params [list $type]
	if {$name ne {}} {
	    set u [string first "&" [string map {&& x} $name]]
	    lappend params -label [string map {&& & & {}} $name]
	    if {$u >= 0} {
		lappend params -underline $u
	    }
	}
	switch -- $type {
	    "cascade" {
		set submenu [string tolower [string map {& ""} [lindex $i 1]]]
		lappend params -menu $m.$submenu
	    }
	    "command" {
		lappend params -command $thing
	    }
	    "radiobutton" {
		lappend params -variable [lindex $thing 0] \
		    -value [lindex $thing 1]
	    }
	}
	set tail [lrange $i 4 end]
	regsub -all {\yMeta1\y} $tail $Meta1 tail
	eval $m add $params $tail
	if {$type eq "cascade"} {
	    makemenu $m.$submenu $thing
	}
    }
}

# translate string and remove ampersands
proc mca {str} {
    return [string map {&& & & {}} [mc $str]]
}

proc cleardropsel {w} {
    $w selection clear
}
proc makedroplist {w varname args} {
    global use_ttk
    if {$use_ttk} {
        set width 0
        foreach label $args {
            set cx [string length $label]
            if {$cx > $width} {set width $cx}
        }
	set gm [ttk::combobox $w -width $width -state readonly\
		    -textvariable $varname -values $args \
		    -exportselection false]
	bind $gm <<ComboboxSelected>> [list $gm selection clear]
    } else {
	set gm [eval [linsert $args 0 tk_optionMenu $w $varname]]
    }
    return $gm
}

proc makewindow {} {
    global canv canv2 canv3 linespc charspc ctext cflist cscroll
    global tabstop
    global findtype findtypemenu findloc findstring fstring geometry
    global entries sha1entry sha1string sha1but
    global diffcontextstring diffcontext
    global ignorespace
    global maincursor textcursor curtextcursor
    global rowctxmenu fakerowmenu mergemax wrapcomment
    global highlight_files gdttype
    global searchstring sstring
    global bgcolor fgcolor bglist fglist diffcolors selectbgcolor
    global uifgcolor uifgdisabledcolor
    global filesepbgcolor filesepfgcolor
    global mergecolors foundbgcolor currentsearchhitbgcolor
    global headctxmenu progresscanv progressitem progresscoords statusw
    global fprogitem fprogcoord lastprogupdate progupdatepending
    global rprogitem rprogcoord rownumsel numcommits
    global have_tk85 use_ttk NS
    global git_version
    global worddiff

    # The "mc" arguments here are purely so that xgettext
    # sees the following string as needing to be translated
    set file {
	mc "File" cascade {
	    {mc "Update" command updatecommits -accelerator F5}
	    {mc "Reload" command reloadcommits -accelerator Shift-F5}
	    {mc "Reread references" command rereadrefs}
	    {mc "List references" command showrefs -accelerator F2}
	    {xx "" separator}
	    {mc "Start git gui" command {exec git gui &}}
	    {xx "" separator}
	    {mc "Quit" command doquit -accelerator Meta1-Q}
	}}
    set edit {
	mc "Edit" cascade {
	    {mc "Preferences" command doprefs}
	}}
    set view {
	mc "View" cascade {
	    {mc "New view..." command {newview 0} -accelerator Shift-F4}
	    {mc "Edit view..." command editview -state disabled -accelerator F4}
	    {mc "Delete view" command delview -state disabled}
	    {xx "" separator}
	    {mc "All files" radiobutton {selectedview 0} -command {showview 0}}
	}}
    if {[tk windowingsystem] ne "aqua"} {
	set help {
	mc "Help" cascade {
	    {mc "About gitk" command about}
	    {mc "Key bindings" command keys}
	}}
	set bar [list $file $edit $view $help]
    } else {
	proc ::tk::mac::ShowPreferences {} {doprefs}
	proc ::tk::mac::Quit {} {doquit}
	lset file end [lreplace [lindex $file end] end-1 end]
	set apple {
	xx "Apple" cascade {
	    {mc "About gitk" command about}
	    {xx "" separator}
	}}
	set help {
	mc "Help" cascade {
	    {mc "Key bindings" command keys}
	}}
	set bar [list $apple $file $view $help]
    }
    makemenu .bar $bar
    . configure -menu .bar

    if {$use_ttk} {
        # cover the non-themed toplevel with a themed frame.
        place [ttk::frame ._main_background] -x 0 -y 0 -relwidth 1 -relheight 1
    }

    # the gui has upper and lower half, parts of a paned window.
    ${NS}::panedwindow .ctop -orient vertical

    # possibly use assumed geometry
    if {![info exists geometry(pwsash0)]} {
        set geometry(topheight) [expr {15 * $linespc}]
        set geometry(topwidth) [expr {80 * $charspc}]
        set geometry(botheight) [expr {15 * $linespc}]
        set geometry(botwidth) [expr {50 * $charspc}]
        set geometry(pwsash0) [list [expr {40 * $charspc}] 2]
        set geometry(pwsash1) [list [expr {60 * $charspc}] 2]
    }

    # the upper half will have a paned window, a scroll bar to the right, and some stuff below
    ${NS}::frame .tf -height $geometry(topheight) -width $geometry(topwidth)
    ${NS}::frame .tf.histframe
    ${NS}::panedwindow .tf.histframe.pwclist -orient horizontal
    if {!$use_ttk} {
	.tf.histframe.pwclist configure -sashpad 0 -handlesize 4
    }

    # create three canvases
    set cscroll .tf.histframe.csb
    set canv .tf.histframe.pwclist.canv
    canvas $canv \
	-selectbackground $selectbgcolor \
	-background $bgcolor -bd 0 \
	-yscrollincr $linespc -yscrollcommand "scrollcanv $cscroll"
    .tf.histframe.pwclist add $canv
    set canv2 .tf.histframe.pwclist.canv2
    canvas $canv2 \
	-selectbackground $selectbgcolor \
	-background $bgcolor -bd 0 -yscrollincr $linespc
    .tf.histframe.pwclist add $canv2
    set canv3 .tf.histframe.pwclist.canv3
    canvas $canv3 \
	-selectbackground $selectbgcolor \
	-background $bgcolor -bd 0 -yscrollincr $linespc
    .tf.histframe.pwclist add $canv3
    if {$use_ttk} {
	bind .tf.histframe.pwclist <Map> {
	    bind %W <Map> {}
	    .tf.histframe.pwclist sashpos 1 [lindex $::geometry(pwsash1) 0]
	    .tf.histframe.pwclist sashpos 0 [lindex $::geometry(pwsash0) 0]
	}
    } else {
	eval .tf.histframe.pwclist sash place 0 $geometry(pwsash0)
	eval .tf.histframe.pwclist sash place 1 $geometry(pwsash1)
    }

    # a scroll bar to rule them
    ${NS}::scrollbar $cscroll -command {allcanvs yview}
    if {!$use_ttk} {$cscroll configure -highlightthickness 0}
    pack $cscroll -side right -fill y
    bind .tf.histframe.pwclist <Configure> {resizeclistpanes %W %w}
    lappend bglist $canv $canv2 $canv3
    pack .tf.histframe.pwclist -fill both -expand 1 -side left

    # we have two button bars at bottom of top frame. Bar 1
    ${NS}::frame .tf.bar
    ${NS}::frame .tf.lbar -height 15

    set sha1entry .tf.bar.sha1
    set entries $sha1entry
    set sha1but .tf.bar.sha1label
    button $sha1but -text "[mc "SHA1 ID:"] " -state disabled -relief flat \
	-command gotocommit -width 8
    $sha1but conf -disabledforeground [$sha1but cget -foreground]
    pack .tf.bar.sha1label -side left
    ${NS}::entry $sha1entry -width 40 -font textfont -textvariable sha1string
    trace add variable sha1string write sha1change
    pack $sha1entry -side left -pady 2

    set bm_left_data {
	#define left_width 16
	#define left_height 16
	static unsigned char left_bits[] = {
	0x00, 0x00, 0xc0, 0x01, 0xe0, 0x00, 0x70, 0x00, 0x38, 0x00, 0x1c, 0x00,
	0x0e, 0x00, 0xff, 0x7f, 0xff, 0x7f, 0xff, 0x7f, 0x0e, 0x00, 0x1c, 0x00,
	0x38, 0x00, 0x70, 0x00, 0xe0, 0x00, 0xc0, 0x01};
    }
    set bm_right_data {
	#define right_width 16
	#define right_height 16
	static unsigned char right_bits[] = {
	0x00, 0x00, 0xc0, 0x01, 0x80, 0x03, 0x00, 0x07, 0x00, 0x0e, 0x00, 0x1c,
	0x00, 0x38, 0xff, 0x7f, 0xff, 0x7f, 0xff, 0x7f, 0x00, 0x38, 0x00, 0x1c,
	0x00, 0x0e, 0x00, 0x07, 0x80, 0x03, 0xc0, 0x01};
    }
    image create bitmap bm-left -data $bm_left_data -foreground $uifgcolor
    image create bitmap bm-left-gray -data $bm_left_data -foreground $uifgdisabledcolor
    image create bitmap bm-right -data $bm_right_data -foreground $uifgcolor
    image create bitmap bm-right-gray -data $bm_right_data -foreground $uifgdisabledcolor

    ${NS}::button .tf.bar.leftbut -command goback -state disabled -width 26
    if {$use_ttk} {
	.tf.bar.leftbut configure -image [list bm-left disabled bm-left-gray]
    } else {
	.tf.bar.leftbut configure -image bm-left
    }
    pack .tf.bar.leftbut -side left -fill y
    ${NS}::button .tf.bar.rightbut -command goforw -state disabled -width 26
    if {$use_ttk} {
	.tf.bar.rightbut configure -image [list bm-right disabled bm-right-gray]
    } else {
	.tf.bar.rightbut configure -image bm-right
    }
    pack .tf.bar.rightbut -side left -fill y

    ${NS}::label .tf.bar.rowlabel -text [mc "Row"]
    set rownumsel {}
    ${NS}::label .tf.bar.rownum -width 7 -textvariable rownumsel \
	-relief sunken -anchor e
    ${NS}::label .tf.bar.rowlabel2 -text "/"
    ${NS}::label .tf.bar.numcommits -width 7 -textvariable numcommits \
	-relief sunken -anchor e
    pack .tf.bar.rowlabel .tf.bar.rownum .tf.bar.rowlabel2 .tf.bar.numcommits \
	-side left
    if {!$use_ttk} {
        foreach w {rownum numcommits} {.tf.bar.$w configure -font textfont}
    }
    global selectedline
    trace add variable selectedline write selectedline_change

    # Status label and progress bar
    set statusw .tf.bar.status
    ${NS}::label $statusw -width 15 -relief sunken
    pack $statusw -side left -padx 5
    if {$use_ttk} {
	set progresscanv [ttk::progressbar .tf.bar.progress]
    } else {
	set h [expr {[font metrics uifont -linespace] + 2}]
	set progresscanv .tf.bar.progress
	canvas $progresscanv -relief sunken -height $h -borderwidth 2
	set progressitem [$progresscanv create rect -1 0 0 $h -fill green]
	set fprogitem [$progresscanv create rect -1 0 0 $h -fill yellow]
	set rprogitem [$progresscanv create rect -1 0 0 $h -fill red]
    }
    pack $progresscanv -side right -expand 1 -fill x -padx {0 2}
    set progresscoords {0 0}
    set fprogcoord 0
    set rprogcoord 0
    bind $progresscanv <Configure> adjustprogress
    set lastprogupdate [clock clicks -milliseconds]
    set progupdatepending 0

    # build up the bottom bar of upper window
    ${NS}::label .tf.lbar.flabel -text "[mc "Find"] "

    set bm_down_data {
	#define down_width 16
	#define down_height 16
	static unsigned char down_bits[] = {
	0x80, 0x01, 0x80, 0x01, 0x80, 0x01, 0x80, 0x01,
	0x80, 0x01, 0x80, 0x01, 0x80, 0x01, 0x80, 0x01,
	0x87, 0xe1, 0x8e, 0x71, 0x9c, 0x39, 0xb8, 0x1d,
	0xf0, 0x0f, 0xe0, 0x07, 0xc0, 0x03, 0x80, 0x01};
    }
    image create bitmap bm-down -data $bm_down_data -foreground $uifgcolor
    ${NS}::button .tf.lbar.fnext -width 26 -command {dofind 1 1}
    .tf.lbar.fnext configure -image bm-down

    set bm_up_data {
	#define up_width 16
	#define up_height 16
	static unsigned char up_bits[] = {
	0x80, 0x01, 0xc0, 0x03, 0xe0, 0x07, 0xf0, 0x0f,
	0xb8, 0x1d, 0x9c, 0x39, 0x8e, 0x71, 0x87, 0xe1,
	0x80, 0x01, 0x80, 0x01, 0x80, 0x01, 0x80, 0x01,
	0x80, 0x01, 0x80, 0x01, 0x80, 0x01, 0x80, 0x01};
    }
    image create bitmap bm-up -data $bm_up_data -foreground $uifgcolor
    ${NS}::button .tf.lbar.fprev -width 26 -command {dofind -1 1}
    .tf.lbar.fprev configure -image bm-up

    ${NS}::label .tf.lbar.flab2 -text " [mc "commit"] "

    pack .tf.lbar.flabel .tf.lbar.fnext .tf.lbar.fprev .tf.lbar.flab2 \
	-side left -fill y
    set gdttype [mc "containing:"]
    set gm [makedroplist .tf.lbar.gdttype gdttype \
		[mc "containing:"] \
		[mc "touching paths:"] \
		[mc "adding/removing string:"] \
		[mc "changing lines matching:"]]
    trace add variable gdttype write gdttype_change
    pack .tf.lbar.gdttype -side left -fill y

    set findstring {}
    set fstring .tf.lbar.findstring
    lappend entries $fstring
    ${NS}::entry $fstring -width 30 -textvariable findstring
    trace add variable findstring write find_change
    set findtype [mc "Exact"]
    set findtypemenu [makedroplist .tf.lbar.findtype \
			  findtype [mc "Exact"] [mc "IgnCase"] [mc "Regexp"]]
    trace add variable findtype write findcom_change
    set findloc [mc "All fields"]
    makedroplist .tf.lbar.findloc findloc [mc "All fields"] [mc "Headline"] \
	[mc "Comments"] [mc "Author"] [mc "Committer"]
    trace add variable findloc write find_change
    pack .tf.lbar.findloc -side right
    pack .tf.lbar.findtype -side right
    pack $fstring -side left -expand 1 -fill x

    # Finish putting the upper half of the viewer together
    pack .tf.lbar -in .tf -side bottom -fill x
    pack .tf.bar -in .tf -side bottom -fill x
    pack .tf.histframe -fill both -side top -expand 1
    .ctop add .tf
    if {!$use_ttk} {
	.ctop paneconfigure .tf -height $geometry(topheight)
	.ctop paneconfigure .tf -width $geometry(topwidth)
    }

    # now build up the bottom
    ${NS}::panedwindow .pwbottom -orient horizontal

    # lower left, a text box over search bar, scroll bar to the right
    # if we know window height, then that will set the lower text height, otherwise
    # we set lower text height which will drive window height
    if {[info exists geometry(main)]} {
	${NS}::frame .bleft -width $geometry(botwidth)
    } else {
	${NS}::frame .bleft -width $geometry(botwidth) -height $geometry(botheight)
    }
    ${NS}::frame .bleft.top
    ${NS}::frame .bleft.mid
    ${NS}::frame .bleft.bottom

    ${NS}::button .bleft.top.search -text [mc "Search"] -command dosearch
    pack .bleft.top.search -side left -padx 5
    set sstring .bleft.top.sstring
    set searchstring ""
    ${NS}::entry $sstring -width 20 -textvariable searchstring
    lappend entries $sstring
    trace add variable searchstring write incrsearch
    pack $sstring -side left -expand 1 -fill x
    ${NS}::radiobutton .bleft.mid.diff -text [mc "Diff"] \
	-command changediffdisp -variable diffelide -value {0 0}
    ${NS}::radiobutton .bleft.mid.old -text [mc "Old version"] \
	-command changediffdisp -variable diffelide -value {0 1}
    ${NS}::radiobutton .bleft.mid.new -text [mc "New version"] \
	-command changediffdisp -variable diffelide -value {1 0}
    ${NS}::label .bleft.mid.labeldiffcontext -text "      [mc "Lines of context"]: "
    pack .bleft.mid.diff .bleft.mid.old .bleft.mid.new -side left
    spinbox .bleft.mid.diffcontext -width 5 \
	-from 0 -increment 1 -to 10000000 \
	-validate all -validatecommand "diffcontextvalidate %P" \
	-textvariable diffcontextstring
    .bleft.mid.diffcontext set $diffcontext
    trace add variable diffcontextstring write diffcontextchange
    lappend entries .bleft.mid.diffcontext
    pack .bleft.mid.labeldiffcontext .bleft.mid.diffcontext -side left
    ${NS}::checkbutton .bleft.mid.ignspace -text [mc "Ignore space change"] \
	-command changeignorespace -variable ignorespace
    pack .bleft.mid.ignspace -side left -padx 5

    set worddiff [mc "Line diff"]
    if {[package vcompare $git_version "1.7.2"] >= 0} {
	makedroplist .bleft.mid.worddiff worddiff [mc "Line diff"] \
	    [mc "Markup words"] [mc "Color words"]
	trace add variable worddiff write changeworddiff
	pack .bleft.mid.worddiff -side left -padx 5
    }

    set ctext .bleft.bottom.ctext
    text $ctext -background $bgcolor -foreground $fgcolor \
	-state disabled -font textfont \
	-yscrollcommand scrolltext -wrap none \
	-xscrollcommand ".bleft.bottom.sbhorizontal set"
    if {$have_tk85} {
	$ctext conf -tabstyle wordprocessor
    }
    ${NS}::scrollbar .bleft.bottom.sb -command "$ctext yview"
    ${NS}::scrollbar .bleft.bottom.sbhorizontal -command "$ctext xview" -orient h
    pack .bleft.top -side top -fill x
    pack .bleft.mid -side top -fill x
    grid $ctext .bleft.bottom.sb -sticky nsew
    grid .bleft.bottom.sbhorizontal -sticky ew
    grid columnconfigure .bleft.bottom 0 -weight 1
    grid rowconfigure .bleft.bottom 0 -weight 1
    grid rowconfigure .bleft.bottom 1 -weight 0
    pack .bleft.bottom -side top -fill both -expand 1
    lappend bglist $ctext
    lappend fglist $ctext

    $ctext tag conf comment -wrap $wrapcomment
    $ctext tag conf filesep -font textfontbold -fore $filesepfgcolor -back $filesepbgcolor
    $ctext tag conf hunksep -fore [lindex $diffcolors 2]
    $ctext tag conf d0 -fore [lindex $diffcolors 0]
    $ctext tag conf dresult -fore [lindex $diffcolors 1]
    $ctext tag conf m0 -fore [lindex $mergecolors 0]
    $ctext tag conf m1 -fore [lindex $mergecolors 1]
    $ctext tag conf m2 -fore [lindex $mergecolors 2]
    $ctext tag conf m3 -fore [lindex $mergecolors 3]
    $ctext tag conf m4 -fore [lindex $mergecolors 4]
    $ctext tag conf m5 -fore [lindex $mergecolors 5]
    $ctext tag conf m6 -fore [lindex $mergecolors 6]
    $ctext tag conf m7 -fore [lindex $mergecolors 7]
    $ctext tag conf m8 -fore [lindex $mergecolors 8]
    $ctext tag conf m9 -fore [lindex $mergecolors 9]
    $ctext tag conf m10 -fore [lindex $mergecolors 10]
    $ctext tag conf m11 -fore [lindex $mergecolors 11]
    $ctext tag conf m12 -fore [lindex $mergecolors 12]
    $ctext tag conf m13 -fore [lindex $mergecolors 13]
    $ctext tag conf m14 -fore [lindex $mergecolors 14]
    $ctext tag conf m15 -fore [lindex $mergecolors 15]
    $ctext tag conf mmax -fore darkgrey
    set mergemax 16
    $ctext tag conf mresult -font textfontbold
    $ctext tag conf msep -font textfontbold
    $ctext tag conf found -back $foundbgcolor
    $ctext tag conf currentsearchhit -back $currentsearchhitbgcolor
    $ctext tag conf wwrap -wrap word -lmargin2 1c
    $ctext tag conf bold -font textfontbold

    .pwbottom add .bleft
    if {!$use_ttk} {
	.pwbottom paneconfigure .bleft -width $geometry(botwidth)
    }

    # lower right
    ${NS}::frame .bright
    ${NS}::frame .bright.mode
    ${NS}::radiobutton .bright.mode.patch -text [mc "Patch"] \
	-command reselectline -variable cmitmode -value "patch"
    ${NS}::radiobutton .bright.mode.tree -text [mc "Tree"] \
	-command reselectline -variable cmitmode -value "tree"
    grid .bright.mode.patch .bright.mode.tree -sticky ew
    pack .bright.mode -side top -fill x
    set cflist .bright.cfiles
    set indent [font measure mainfont "nn"]
    text $cflist \
	-selectbackground $selectbgcolor \
	-background $bgcolor -foreground $fgcolor \
	-font mainfont \
	-tabs [list $indent [expr {2 * $indent}]] \
	-yscrollcommand ".bright.sb set" \
	-cursor [. cget -cursor] \
	-spacing1 1 -spacing3 1
    lappend bglist $cflist
    lappend fglist $cflist
    ${NS}::scrollbar .bright.sb -command "$cflist yview"
    pack .bright.sb -side right -fill y
    pack $cflist -side left -fill both -expand 1
    $cflist tag configure highlight \
	-background [$cflist cget -selectbackground]
    $cflist tag configure bold -font mainfontbold

    .pwbottom add .bright
    .ctop add .pwbottom

    # restore window width & height if known
    if {[info exists geometry(main)]} {
	if {[scan $geometry(main) "%dx%d" w h] >= 2} {
	    if {$w > [winfo screenwidth .]} {
		set w [winfo screenwidth .]
	    }
	    if {$h > [winfo screenheight .]} {
		set h [winfo screenheight .]
	    }
	    wm geometry . "${w}x$h"
	}
    }

    if {[info exists geometry(state)] && $geometry(state) eq "zoomed"} {
        wm state . $geometry(state)
    }

    if {[tk windowingsystem] eq {aqua}} {
        set M1B M1
        set ::BM "3"
    } else {
        set M1B Control
        set ::BM "2"
    }

    if {$use_ttk} {
        bind .ctop <Map> {
            bind %W <Map> {}
            %W sashpos 0 $::geometry(topheight)
        }
        bind .pwbottom <Map> {
            bind %W <Map> {}
            %W sashpos 0 $::geometry(botwidth)
        }
    }

    bind .pwbottom <Configure> {resizecdetpanes %W %w}
    pack .ctop -fill both -expand 1
    bindall <1> {selcanvline %W %x %y}
    #bindall <B1-Motion> {selcanvline %W %x %y}
    if {[tk windowingsystem] == "win32"} {
	bind . <MouseWheel> { windows_mousewheel_redirector %W %X %Y %D }
	bind $ctext <MouseWheel> { windows_mousewheel_redirector %W %X %Y %D ; break }
    } else {
	bindall <ButtonRelease-4> "allcanvs yview scroll -5 units"
	bindall <ButtonRelease-5> "allcanvs yview scroll 5 units"
        if {[tk windowingsystem] eq "aqua"} {
            bindall <MouseWheel> {
                set delta [expr {- (%D)}]
                allcanvs yview scroll $delta units
            }
            bindall <Shift-MouseWheel> {
                set delta [expr {- (%D)}]
                $canv xview scroll $delta units
            }
        }
    }
    bindall <$::BM> "canvscan mark %W %x %y"
    bindall <B$::BM-Motion> "canvscan dragto %W %x %y"
    bind all <$M1B-Key-w> {destroy [winfo toplevel %W]}
    bind . <$M1B-Key-w> doquit
    bindkey <Home> selfirstline
    bindkey <End> sellastline
    bind . <Key-Up> "selnextline -1"
    bind . <Key-Down> "selnextline 1"
    bind . <Shift-Key-Up> "dofind -1 0"
    bind . <Shift-Key-Down> "dofind 1 0"
    bindkey <Key-Right> "goforw"
    bindkey <Key-Left> "goback"
    bind . <Key-Prior> "selnextpage -1"
    bind . <Key-Next> "selnextpage 1"
    bind . <$M1B-Home> "allcanvs yview moveto 0.0"
    bind . <$M1B-End> "allcanvs yview moveto 1.0"
    bind . <$M1B-Key-Up> "allcanvs yview scroll -1 units"
    bind . <$M1B-Key-Down> "allcanvs yview scroll 1 units"
    bind . <$M1B-Key-Prior> "allcanvs yview scroll -1 pages"
    bind . <$M1B-Key-Next> "allcanvs yview scroll 1 pages"
    bindkey <Key-Delete> "$ctext yview scroll -1 pages"
    bindkey <Key-BackSpace> "$ctext yview scroll -1 pages"
    bindkey <Key-space> "$ctext yview scroll 1 pages"
    bindkey p "selnextline -1"
    bindkey n "selnextline 1"
    bindkey z "goback"
    bindkey x "goforw"
    bindkey k "selnextline -1"
    bindkey j "selnextline 1"
    bindkey h "goback"
    bindkey l "goforw"
    bindkey b prevfile
    bindkey d "$ctext yview scroll 18 units"
    bindkey u "$ctext yview scroll -18 units"
    bindkey / {focus $fstring}
    bindkey <Key-KP_Divide> {focus $fstring}
    bindkey <Key-Return> {dofind 1 1}
    bindkey ? {dofind -1 1}
    bindkey f nextfile
    bind . <F5> updatecommits
    bindmodfunctionkey Shift 5 reloadcommits
    bind . <F2> showrefs
    bindmodfunctionkey Shift 4 {newview 0}
    bind . <F4> edit_or_newview
    bind . <$M1B-q> doquit
    bind . <$M1B-f> {dofind 1 1}
    bind . <$M1B-g> {dofind 1 0}
    bind . <$M1B-r> dosearchback
    bind . <$M1B-s> dosearch
    bind . <$M1B-equal> {incrfont 1}
    bind . <$M1B-plus> {incrfont 1}
    bind . <$M1B-KP_Add> {incrfont 1}
    bind . <$M1B-minus> {incrfont -1}
    bind . <$M1B-KP_Subtract> {incrfont -1}
    wm protocol . WM_DELETE_WINDOW doquit
    bind . <Destroy> {stop_backends}
    bind . <Button-1> "click %W"
    bind $fstring <Key-Return> {dofind 1 1}
    bind $sha1entry <Key-Return> {gotocommit; break}
    bind $sha1entry <<PasteSelection>> clearsha1
    bind $sha1entry <<Paste>> clearsha1
    bind $cflist <1> {sel_flist %W %x %y; break}
    bind $cflist <B1-Motion> {sel_flist %W %x %y; break}
    bind $cflist <ButtonRelease-1> {treeclick %W %x %y}
    global ctxbut
    bind $cflist $ctxbut {pop_flist_menu %W %X %Y %x %y}
    bind $ctext $ctxbut {pop_diff_menu %W %X %Y %x %y}
    bind $ctext <Button-1> {focus %W}
    bind $ctext <<Selection>> rehighlight_search_results
    for {set i 1} {$i < 10} {incr i} {
	bind . <$M1B-Key-$i> [list go_to_parent $i]
    }

    set maincursor [. cget -cursor]
    set textcursor [$ctext cget -cursor]
    set curtextcursor $textcursor

    set rowctxmenu .rowctxmenu
    makemenu $rowctxmenu {
	{mc "Diff this -> selected" command {diffvssel 0}}
	{mc "Diff selected -> this" command {diffvssel 1}}
	{mc "Make patch" command mkpatch}
	{mc "Create tag" command mktag}
	{mc "Write commit to file" command writecommit}
	{mc "Create new branch" command mkbranch}
	{mc "Cherry-pick this commit" command cherrypick}
	{mc "Reset HEAD branch to here" command resethead}
	{mc "Mark this commit" command markhere}
	{mc "Return to mark" command gotomark}
	{mc "Find descendant of this and mark" command find_common_desc}
	{mc "Compare with marked commit" command compare_commits}
	{mc "Diff this -> marked commit" command {diffvsmark 0}}
	{mc "Diff marked commit -> this" command {diffvsmark 1}}
	{mc "Revert this commit" command revert}
    }
    $rowctxmenu configure -tearoff 0

    set fakerowmenu .fakerowmenu
    makemenu $fakerowmenu {
	{mc "Diff this -> selected" command {diffvssel 0}}
	{mc "Diff selected -> this" command {diffvssel 1}}
	{mc "Make patch" command mkpatch}
	{mc "Diff this -> marked commit" command {diffvsmark 0}}
	{mc "Diff marked commit -> this" command {diffvsmark 1}}
    }
    $fakerowmenu configure -tearoff 0

    set headctxmenu .headctxmenu
    makemenu $headctxmenu {
	{mc "Check out this branch" command cobranch}
	{mc "Remove this branch" command rmbranch}
    }
    $headctxmenu configure -tearoff 0

    global flist_menu
    set flist_menu .flistctxmenu
    makemenu $flist_menu {
	{mc "Highlight this too" command {flist_hl 0}}
	{mc "Highlight this only" command {flist_hl 1}}
	{mc "External diff" command {external_diff}}
	{mc "Blame parent commit" command {external_blame 1}}
    }
    $flist_menu configure -tearoff 0

    global diff_menu
    set diff_menu .diffctxmenu
    makemenu $diff_menu {
	{mc "Show origin of this line" command show_line_source}
	{mc "Run git gui blame on this line" command {external_blame_diff}}
    }
    $diff_menu configure -tearoff 0
}

# Windows sends all mouse wheel events to the current focused window, not
# the one where the mouse hovers, so bind those events here and redirect
# to the correct window
proc windows_mousewheel_redirector {W X Y D} {
    global canv canv2 canv3
    set w [winfo containing -displayof $W $X $Y]
    if {$w ne ""} {
	set u [expr {$D < 0 ? 5 : -5}]
	if {$w == $canv || $w == $canv2 || $w == $canv3} {
	    allcanvs yview scroll $u units
	} else {
	    catch {
		$w yview scroll $u units
	    }
	}
    }
}

# Update row number label when selectedline changes
proc selectedline_change {n1 n2 op} {
    global selectedline rownumsel

    if {$selectedline eq {}} {
	set rownumsel {}
    } else {
	set rownumsel [expr {$selectedline + 1}]
    }
}

# mouse-2 makes all windows scan vertically, but only the one
# the cursor is in scans horizontally
proc canvscan {op w x y} {
    global canv canv2 canv3
    foreach c [list $canv $canv2 $canv3] {
	if {$c == $w} {
	    $c scan $op $x $y
	} else {
	    $c scan $op 0 $y
	}
    }
}

proc scrollcanv {cscroll f0 f1} {
    $cscroll set $f0 $f1
    drawvisible
    flushhighlights
}

# when we make a key binding for the toplevel, make sure
# it doesn't get triggered when that key is pressed in the
# find string entry widget.
proc bindkey {ev script} {
    global entries
    bind . $ev $script
    set escript [bind Entry $ev]
    if {$escript == {}} {
	set escript [bind Entry <Key>]
    }
    foreach e $entries {
	bind $e $ev "$escript; break"
    }
}

proc bindmodfunctionkey {mod n script} {
    bind . <$mod-F$n> $script
    catch { bind . <$mod-XF86_Switch_VT_$n> $script }
}

# set the focus back to the toplevel for any click outside
# the entry widgets
proc click {w} {
    global ctext entries
    foreach e [concat $entries $ctext] {
	if {$w == $e} return
    }
    focus .
}

# Adjust the progress bar for a change in requested extent or canvas size
proc adjustprogress {} {
    global progresscanv progressitem progresscoords
    global fprogitem fprogcoord lastprogupdate progupdatepending
    global rprogitem rprogcoord use_ttk

    if {$use_ttk} {
	$progresscanv configure -value [expr {int($fprogcoord * 100)}]
	return
    }

    set w [expr {[winfo width $progresscanv] - 4}]
    set x0 [expr {$w * [lindex $progresscoords 0]}]
    set x1 [expr {$w * [lindex $progresscoords 1]}]
    set h [winfo height $progresscanv]
    $progresscanv coords $progressitem $x0 0 $x1 $h
    $progresscanv coords $fprogitem 0 0 [expr {$w * $fprogcoord}] $h
    $progresscanv coords $rprogitem 0 0 [expr {$w * $rprogcoord}] $h
    set now [clock clicks -milliseconds]
    if {$now >= $lastprogupdate + 100} {
	set progupdatepending 0
	update
    } elseif {!$progupdatepending} {
	set progupdatepending 1
	after [expr {$lastprogupdate + 100 - $now}] doprogupdate
    }
}

proc doprogupdate {} {
    global lastprogupdate progupdatepending

    if {$progupdatepending} {
	set progupdatepending 0
	set lastprogupdate [clock clicks -milliseconds]
	update
    }
}

proc savestuff {w} {
    global viewname viewfiles viewargs viewargscmd viewperm nextviewnum
    global use_ttk
    global stuffsaved
    global config_file config_file_tmp
    global config_variables

    if {$stuffsaved} return
    if {![winfo viewable .]} return
    catch {
	if {[file exists $config_file_tmp]} {
	    file delete -force $config_file_tmp
	}
	set f [open $config_file_tmp w]
	if {$::tcl_platform(platform) eq {windows}} {
	    file attributes $config_file_tmp -hidden true
	}
	foreach var_name $config_variables {
	    upvar #0 $var_name var
	    puts $f [list set $var_name $var]
	}

	puts $f "set geometry(main) [wm geometry .]"
	puts $f "set geometry(state) [wm state .]"
	puts $f "set geometry(topwidth) [winfo width .tf]"
	puts $f "set geometry(topheight) [winfo height .tf]"
	if {$use_ttk} {
	    puts $f "set geometry(pwsash0) \"[.tf.histframe.pwclist sashpos 0] 1\""
	    puts $f "set geometry(pwsash1) \"[.tf.histframe.pwclist sashpos 1] 1\""
	} else {
	    puts $f "set geometry(pwsash0) \"[.tf.histframe.pwclist sash coord 0]\""
	    puts $f "set geometry(pwsash1) \"[.tf.histframe.pwclist sash coord 1]\""
	}
	puts $f "set geometry(botwidth) [winfo width .bleft]"
	puts $f "set geometry(botheight) [winfo height .bleft]"

	puts -nonewline $f "set permviews {"
	for {set v 0} {$v < $nextviewnum} {incr v} {
	    if {$viewperm($v)} {
		puts $f "{[list $viewname($v) $viewfiles($v) $viewargs($v) $viewargscmd($v)]}"
	    }
	}
	puts $f "}"
	close $f
	file rename -force $config_file_tmp $config_file
    }
    set stuffsaved 1
}

proc resizeclistpanes {win w} {
    global oldwidth use_ttk
    if {[info exists oldwidth($win)]} {
	if {$use_ttk} {
	    set s0 [$win sashpos 0]
	    set s1 [$win sashpos 1]
	} else {
	    set s0 [$win sash coord 0]
	    set s1 [$win sash coord 1]
	}
	if {$w < 60} {
	    set sash0 [expr {int($w/2 - 2)}]
	    set sash1 [expr {int($w*5/6 - 2)}]
	} else {
	    set factor [expr {1.0 * $w / $oldwidth($win)}]
	    set sash0 [expr {int($factor * [lindex $s0 0])}]
	    set sash1 [expr {int($factor * [lindex $s1 0])}]
	    if {$sash0 < 30} {
		set sash0 30
	    }
	    if {$sash1 < $sash0 + 20} {
		set sash1 [expr {$sash0 + 20}]
	    }
	    if {$sash1 > $w - 10} {
		set sash1 [expr {$w - 10}]
		if {$sash0 > $sash1 - 20} {
		    set sash0 [expr {$sash1 - 20}]
		}
	    }
	}
	if {$use_ttk} {
	    $win sashpos 0 $sash0
	    $win sashpos 1 $sash1
	} else {
	    $win sash place 0 $sash0 [lindex $s0 1]
	    $win sash place 1 $sash1 [lindex $s1 1]
	}
    }
    set oldwidth($win) $w
}

proc resizecdetpanes {win w} {
    global oldwidth use_ttk
    if {[info exists oldwidth($win)]} {
	if {$use_ttk} {
	    set s0 [$win sashpos 0]
	} else {
	    set s0 [$win sash coord 0]
	}
	if {$w < 60} {
	    set sash0 [expr {int($w*3/4 - 2)}]
	} else {
	    set factor [expr {1.0 * $w / $oldwidth($win)}]
	    set sash0 [expr {int($factor * [lindex $s0 0])}]
	    if {$sash0 < 45} {
		set sash0 45
	    }
	    if {$sash0 > $w - 15} {
		set sash0 [expr {$w - 15}]
	    }
	}
	if {$use_ttk} {
	    $win sashpos 0 $sash0
	} else {
	    $win sash place 0 $sash0 [lindex $s0 1]
	}
    }
    set oldwidth($win) $w
}

proc allcanvs args {
    global canv canv2 canv3
    eval $canv $args
    eval $canv2 $args
    eval $canv3 $args
}

proc bindall {event action} {
    global canv canv2 canv3
    bind $canv $event $action
    bind $canv2 $event $action
    bind $canv3 $event $action
}

proc about {} {
    global uifont NS
    set w .about
    if {[winfo exists $w]} {
	raise $w
	return
    }
    ttk_toplevel $w
    wm title $w [mc "About gitk"]
    make_transient $w .
    message $w.m -text [mc "
Gitk - a commit viewer for git

Copyright \u00a9 2005-2014 Paul Mackerras

Use and redistribute under the terms of the GNU General Public License"] \
	    -justify center -aspect 400 -border 2 -bg white -relief groove
    pack $w.m -side top -fill x -padx 2 -pady 2
    ${NS}::button $w.ok -text [mc "Close"] -command "destroy $w" -default active
    pack $w.ok -side bottom
    bind $w <Visibility> "focus $w.ok"
    bind $w <Key-Escape> "destroy $w"
    bind $w <Key-Return> "destroy $w"
    tk::PlaceWindow $w widget .
}

proc keys {} {
    global NS
    set w .keys
    if {[winfo exists $w]} {
	raise $w
	return
    }
    if {[tk windowingsystem] eq {aqua}} {
	set M1T Cmd
    } else {
	set M1T Ctrl
    }
    ttk_toplevel $w
    wm title $w [mc "Gitk key bindings"]
    make_transient $w .
    message $w.m -text "
[mc "Gitk key bindings:"]

[mc "<%s-Q>		Quit" $M1T]
[mc "<%s-W>		Close window" $M1T]
[mc "<Home>		Move to first commit"]
[mc "<End>		Move to last commit"]
[mc "<Up>, p, k	Move up one commit"]
[mc "<Down>, n, j	Move down one commit"]
[mc "<Left>, z, h	Go back in history list"]
[mc "<Right>, x, l	Go forward in history list"]
[mc "<%s-n>	Go to n-th parent of current commit in history list" $M1T]
[mc "<PageUp>	Move up one page in commit list"]
[mc "<PageDown>	Move down one page in commit list"]
[mc "<%s-Home>	Scroll to top of commit list" $M1T]
[mc "<%s-End>	Scroll to bottom of commit list" $M1T]
[mc "<%s-Up>	Scroll commit list up one line" $M1T]
[mc "<%s-Down>	Scroll commit list down one line" $M1T]
[mc "<%s-PageUp>	Scroll commit list up one page" $M1T]
[mc "<%s-PageDown>	Scroll commit list down one page" $M1T]
[mc "<Shift-Up>	Find backwards (upwards, later commits)"]
[mc "<Shift-Down>	Find forwards (downwards, earlier commits)"]
[mc "<Delete>, b	Scroll diff view up one page"]
[mc "<Backspace>	Scroll diff view up one page"]
[mc "<Space>		Scroll diff view down one page"]
[mc "u		Scroll diff view up 18 lines"]
[mc "d		Scroll diff view down 18 lines"]
[mc "<%s-F>		Find" $M1T]
[mc "<%s-G>		Move to next find hit" $M1T]
[mc "<Return>	Move to next find hit"]
[mc "/		Focus the search box"]
[mc "?		Move to previous find hit"]
[mc "f		Scroll diff view to next file"]
[mc "<%s-S>		Search for next hit in diff view" $M1T]
[mc "<%s-R>		Search for previous hit in diff view" $M1T]
[mc "<%s-KP+>	Increase font size" $M1T]
[mc "<%s-plus>	Increase font size" $M1T]
[mc "<%s-KP->	Decrease font size" $M1T]
[mc "<%s-minus>	Decrease font size" $M1T]
[mc "<F5>		Update"]
" \
	    -justify left -bg white -border 2 -relief groove
    pack $w.m -side top -fill both -padx 2 -pady 2
    ${NS}::button $w.ok -text [mc "Close"] -command "destroy $w" -default active
    bind $w <Key-Escape> [list destroy $w]
    pack $w.ok -side bottom
    bind $w <Visibility> "focus $w.ok"
    bind $w <Key-Escape> "destroy $w"
    bind $w <Key-Return> "destroy $w"
}

# Procedures for manipulating the file list window at the
# bottom right of the overall window.

proc treeview {w l openlevs} {
    global treecontents treediropen treeheight treeparent treeindex

    set ix 0
    set treeindex() 0
    set lev 0
    set prefix {}
    set prefixend -1
    set prefendstack {}
    set htstack {}
    set ht 0
    set treecontents() {}
    $w conf -state normal
    foreach f $l {
	while {[string range $f 0 $prefixend] ne $prefix} {
	    if {$lev <= $openlevs} {
		$w mark set e:$treeindex($prefix) "end -1c"
		$w mark gravity e:$treeindex($prefix) left
	    }
	    set treeheight($prefix) $ht
	    incr ht [lindex $htstack end]
	    set htstack [lreplace $htstack end end]
	    set prefixend [lindex $prefendstack end]
	    set prefendstack [lreplace $prefendstack end end]
	    set prefix [string range $prefix 0 $prefixend]
	    incr lev -1
	}
	set tail [string range $f [expr {$prefixend+1}] end]
	while {[set slash [string first "/" $tail]] >= 0} {
	    lappend htstack $ht
	    set ht 0
	    lappend prefendstack $prefixend
	    incr prefixend [expr {$slash + 1}]
	    set d [string range $tail 0 $slash]
	    lappend treecontents($prefix) $d
	    set oldprefix $prefix
	    append prefix $d
	    set treecontents($prefix) {}
	    set treeindex($prefix) [incr ix]
	    set treeparent($prefix) $oldprefix
	    set tail [string range $tail [expr {$slash+1}] end]
	    if {$lev <= $openlevs} {
		set ht 1
		set treediropen($prefix) [expr {$lev < $openlevs}]
		set bm [expr {$lev == $openlevs? "tri-rt": "tri-dn"}]
		$w mark set d:$ix "end -1c"
		$w mark gravity d:$ix left
		set str "\n"
		for {set i 0} {$i < $lev} {incr i} {append str "\t"}
		$w insert end $str
		$w image create end -align center -image $bm -padx 1 \
		    -name a:$ix
		$w insert end $d [highlight_tag $prefix]
		$w mark set s:$ix "end -1c"
		$w mark gravity s:$ix left
	    }
	    incr lev
	}
	if {$tail ne {}} {
	    if {$lev <= $openlevs} {
		incr ht
		set str "\n"
		for {set i 0} {$i < $lev} {incr i} {append str "\t"}
		$w insert end $str
		$w insert end $tail [highlight_tag $f]
	    }
	    lappend treecontents($prefix) $tail
	}
    }
    while {$htstack ne {}} {
	set treeheight($prefix) $ht
	incr ht [lindex $htstack end]
	set htstack [lreplace $htstack end end]
	set prefixend [lindex $prefendstack end]
	set prefendstack [lreplace $prefendstack end end]
	set prefix [string range $prefix 0 $prefixend]
    }
    $w conf -state disabled
}

proc linetoelt {l} {
    global treeheight treecontents

    set y 2
    set prefix {}
    while {1} {
	foreach e $treecontents($prefix) {
	    if {$y == $l} {
		return "$prefix$e"
	    }
	    set n 1
	    if {[string index $e end] eq "/"} {
		set n $treeheight($prefix$e)
		if {$y + $n > $l} {
		    append prefix $e
		    incr y
		    break
		}
	    }
	    incr y $n
	}
    }
}

proc highlight_tree {y prefix} {
    global treeheight treecontents cflist

    foreach e $treecontents($prefix) {
	set path $prefix$e
	if {[highlight_tag $path] ne {}} {
	    $cflist tag add bold $y.0 "$y.0 lineend"
	}
	incr y
	if {[string index $e end] eq "/" && $treeheight($path) > 1} {
	    set y [highlight_tree $y $path]
	}
    }
    return $y
}

proc treeclosedir {w dir} {
    global treediropen treeheight treeparent treeindex

    set ix $treeindex($dir)
    $w conf -state normal
    $w delete s:$ix e:$ix
    set treediropen($dir) 0
    $w image configure a:$ix -image tri-rt
    $w conf -state disabled
    set n [expr {1 - $treeheight($dir)}]
    while {$dir ne {}} {
	incr treeheight($dir) $n
	set dir $treeparent($dir)
    }
}

proc treeopendir {w dir} {
    global treediropen treeheight treeparent treecontents treeindex

    set ix $treeindex($dir)
    $w conf -state normal
    $w image configure a:$ix -image tri-dn
    $w mark set e:$ix s:$ix
    $w mark gravity e:$ix right
    set lev 0
    set str "\n"
    set n [llength $treecontents($dir)]
    for {set x $dir} {$x ne {}} {set x $treeparent($x)} {
	incr lev
	append str "\t"
	incr treeheight($x) $n
    }
    foreach e $treecontents($dir) {
	set de $dir$e
	if {[string index $e end] eq "/"} {
	    set iy $treeindex($de)
	    $w mark set d:$iy e:$ix
	    $w mark gravity d:$iy left
	    $w insert e:$ix $str
	    set treediropen($de) 0
	    $w image create e:$ix -align center -image tri-rt -padx 1 \
		-name a:$iy
	    $w insert e:$ix $e [highlight_tag $de]
	    $w mark set s:$iy e:$ix
	    $w mark gravity s:$iy left
	    set treeheight($de) 1
	} else {
	    $w insert e:$ix $str
	    $w insert e:$ix $e [highlight_tag $de]
	}
    }
    $w mark gravity e:$ix right
    $w conf -state disabled
    set treediropen($dir) 1
    set top [lindex [split [$w index @0,0] .] 0]
    set ht [$w cget -height]
    set l [lindex [split [$w index s:$ix] .] 0]
    if {$l < $top} {
	$w yview $l.0
    } elseif {$l + $n + 1 > $top + $ht} {
	set top [expr {$l + $n + 2 - $ht}]
	if {$l < $top} {
	    set top $l
	}
	$w yview $top.0
    }
}

proc treeclick {w x y} {
    global treediropen cmitmode ctext cflist cflist_top

    if {$cmitmode ne "tree"} return
    if {![info exists cflist_top]} return
    set l [lindex [split [$w index "@$x,$y"] "."] 0]
    $cflist tag remove highlight $cflist_top.0 "$cflist_top.0 lineend"
    $cflist tag add highlight $l.0 "$l.0 lineend"
    set cflist_top $l
    if {$l == 1} {
	$ctext yview 1.0
	return
    }
    set e [linetoelt $l]
    if {[string index $e end] ne "/"} {
	showfile $e
    } elseif {$treediropen($e)} {
	treeclosedir $w $e
    } else {
	treeopendir $w $e
    }
}

proc setfilelist {id} {
    global treefilelist cflist jump_to_here

    treeview $cflist $treefilelist($id) 0
    if {$jump_to_here ne {}} {
	set f [lindex $jump_to_here 0]
	if {[lsearch -exact $treefilelist($id) $f] >= 0} {
	    showfile $f
	}
    }
}

image create bitmap tri-rt -background black -foreground blue -data {
    #define tri-rt_width 13
    #define tri-rt_height 13
    static unsigned char tri-rt_bits[] = {
       0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x30, 0x00, 0x70, 0x00, 0xf0, 0x00,
       0xf0, 0x01, 0xf0, 0x00, 0x70, 0x00, 0x30, 0x00, 0x10, 0x00, 0x00, 0x00,
       0x00, 0x00};
} -maskdata {
    #define tri-rt-mask_width 13
    #define tri-rt-mask_height 13
    static unsigned char tri-rt-mask_bits[] = {
       0x08, 0x00, 0x18, 0x00, 0x38, 0x00, 0x78, 0x00, 0xf8, 0x00, 0xf8, 0x01,
       0xf8, 0x03, 0xf8, 0x01, 0xf8, 0x00, 0x78, 0x00, 0x38, 0x00, 0x18, 0x00,
       0x08, 0x00};
}
image create bitmap tri-dn -background black -foreground blue -data {
    #define tri-dn_width 13
    #define tri-dn_height 13
    static unsigned char tri-dn_bits[] = {
       0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xfc, 0x07, 0xf8, 0x03,
       0xf0, 0x01, 0xe0, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
       0x00, 0x00};
} -maskdata {
    #define tri-dn-mask_width 13
    #define tri-dn-mask_height 13
    static unsigned char tri-dn-mask_bits[] = {
       0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x1f, 0xfe, 0x0f, 0xfc, 0x07,
       0xf8, 0x03, 0xf0, 0x01, 0xe0, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
       0x00, 0x00};
}

image create bitmap reficon-T -background black -foreground yellow -data {
    #define tagicon_width 13
    #define tagicon_height 9
    static unsigned char tagicon_bits[] = {
       0x00, 0x00, 0x00, 0x00, 0xf0, 0x07, 0xf8, 0x07,
       0xfc, 0x07, 0xf8, 0x07, 0xf0, 0x07, 0x00, 0x00, 0x00, 0x00};
} -maskdata {
    #define tagicon-mask_width 13
    #define tagicon-mask_height 9
    static unsigned char tagicon-mask_bits[] = {
       0x00, 0x00, 0xf0, 0x0f, 0xf8, 0x0f, 0xfc, 0x0f,
       0xfe, 0x0f, 0xfc, 0x0f, 0xf8, 0x0f, 0xf0, 0x0f, 0x00, 0x00};
}
set rectdata {
    #define headicon_width 13
    #define headicon_height 9
    static unsigned char headicon_bits[] = {
       0x00, 0x00, 0x00, 0x00, 0xf8, 0x07, 0xf8, 0x07,
       0xf8, 0x07, 0xf8, 0x07, 0xf8, 0x07, 0x00, 0x00, 0x00, 0x00};
}
set rectmask {
    #define headicon-mask_width 13
    #define headicon-mask_height 9
    static unsigned char headicon-mask_bits[] = {
       0x00, 0x00, 0xfc, 0x0f, 0xfc, 0x0f, 0xfc, 0x0f,
       0xfc, 0x0f, 0xfc, 0x0f, 0xfc, 0x0f, 0xfc, 0x0f, 0x00, 0x00};
}
image create bitmap reficon-H -background black -foreground green \
    -data $rectdata -maskdata $rectmask
image create bitmap reficon-o -background black -foreground "#ddddff" \
    -data $rectdata -maskdata $rectmask

proc init_flist {first} {
    global cflist cflist_top difffilestart

    $cflist conf -state normal
    $cflist delete 0.0 end
    if {$first ne {}} {
	$cflist insert end $first
	set cflist_top 1
	$cflist tag add highlight 1.0 "1.0 lineend"
    } else {
	catch {unset cflist_top}
    }
    $cflist conf -state disabled
    set difffilestart {}
}

proc highlight_tag {f} {
    global highlight_paths

    foreach p $highlight_paths {
	if {[string match $p $f]} {
	    return "bold"
	}
    }
    return {}
}

proc highlight_filelist {} {
    global cmitmode cflist

    $cflist conf -state normal
    if {$cmitmode ne "tree"} {
	set end [lindex [split [$cflist index end] .] 0]
	for {set l 2} {$l < $end} {incr l} {
	    set line [$cflist get $l.0 "$l.0 lineend"]
	    if {[highlight_tag $line] ne {}} {
		$cflist tag add bold $l.0 "$l.0 lineend"
	    }
	}
    } else {
	highlight_tree 2 {}
    }
    $cflist conf -state disabled
}

proc unhighlight_filelist {} {
    global cflist

    $cflist conf -state normal
    $cflist tag remove bold 1.0 end
    $cflist conf -state disabled
}

proc add_flist {fl} {
    global cflist

    $cflist conf -state normal
    foreach f $fl {
	$cflist insert end "\n"
	$cflist insert end $f [highlight_tag $f]
    }
    $cflist conf -state disabled
}

proc sel_flist {w x y} {
    global ctext difffilestart cflist cflist_top cmitmode

    if {$cmitmode eq "tree"} return
    if {![info exists cflist_top]} return
    set l [lindex [split [$w index "@$x,$y"] "."] 0]
    $cflist tag remove highlight $cflist_top.0 "$cflist_top.0 lineend"
    $cflist tag add highlight $l.0 "$l.0 lineend"
    set cflist_top $l
    if {$l == 1} {
	$ctext yview 1.0
    } else {
	catch {$ctext yview [lindex $difffilestart [expr {$l - 2}]]}
    }
    suppress_highlighting_file_for_current_scrollpos
}

proc pop_flist_menu {w X Y x y} {
    global ctext cflist cmitmode flist_menu flist_menu_file
    global treediffs diffids

    stopfinding
    set l [lindex [split [$w index "@$x,$y"] "."] 0]
    if {$l <= 1} return
    if {$cmitmode eq "tree"} {
	set e [linetoelt $l]
	if {[string index $e end] eq "/"} return
    } else {
	set e [lindex $treediffs($diffids) [expr {$l-2}]]
    }
    set flist_menu_file $e
    set xdiffstate "normal"
    if {$cmitmode eq "tree"} {
	set xdiffstate "disabled"
    }
    # Disable "External diff" item in tree mode
    $flist_menu entryconf 2 -state $xdiffstate
    tk_popup $flist_menu $X $Y
}

proc find_ctext_fileinfo {line} {
    global ctext_file_names ctext_file_lines

    set ok [bsearch $ctext_file_lines $line]
    set tline [lindex $ctext_file_lines $ok]

    if {$ok >= [llength $ctext_file_lines] || $line < $tline} {
        return {}
    } else {
        return [list [lindex $ctext_file_names $ok] $tline]
    }
}

proc pop_diff_menu {w X Y x y} {
    global ctext diff_menu flist_menu_file
    global diff_menu_txtpos diff_menu_line
    global diff_menu_filebase

    set diff_menu_txtpos [split [$w index "@$x,$y"] "."]
    set diff_menu_line [lindex $diff_menu_txtpos 0]
    # don't pop up the menu on hunk-separator or file-separator lines
    if {[lsearch -glob [$ctext tag names $diff_menu_line.0] "*sep"] >= 0} {
	return
    }
    stopfinding
    set f [find_ctext_fileinfo $diff_menu_line]
    if {$f eq {}} return
    set flist_menu_file [lindex $f 0]
    set diff_menu_filebase [lindex $f 1]
    tk_popup $diff_menu $X $Y
}

proc flist_hl {only} {
    global flist_menu_file findstring gdttype

    set x [shellquote $flist_menu_file]
    if {$only || $findstring eq {} || $gdttype ne [mc "touching paths:"]} {
	set findstring $x
    } else {
	append findstring " " $x
    }
    set gdttype [mc "touching paths:"]
}

proc gitknewtmpdir {} {
    global diffnum gitktmpdir gitdir env

    if {![info exists gitktmpdir]} {
	if {[info exists env(GITK_TMPDIR)]} {
	    set tmpdir $env(GITK_TMPDIR)
	} elseif {[info exists env(TMPDIR)]} {
	    set tmpdir $env(TMPDIR)
	} else {
	    set tmpdir $gitdir
	}
	set gitktmpformat [file join $tmpdir ".gitk-tmp.XXXXXX"]
	if {[catch {set gitktmpdir [exec mktemp -d $gitktmpformat]}]} {
	    set gitktmpdir [file join $gitdir [format ".gitk-tmp.%s" [pid]]]
	}
	if {[catch {file mkdir $gitktmpdir} err]} {
	    error_popup "[mc "Error creating temporary directory %s:" $gitktmpdir] $err"
	    unset gitktmpdir
	    return {}
	}
	set diffnum 0
    }
    incr diffnum
    set diffdir [file join $gitktmpdir $diffnum]
    if {[catch {file mkdir $diffdir} err]} {
	error_popup "[mc "Error creating temporary directory %s:" $diffdir] $err"
	return {}
    }
    return $diffdir
}

proc save_file_from_commit {filename output what} {
    global nullfile

    if {[catch {exec git show $filename -- > $output} err]} {
	if {[string match "fatal: bad revision *" $err]} {
	    return $nullfile
	}
	error_popup "[mc "Error getting \"%s\" from %s:" $filename $what] $err"
	return {}
    }
    return $output
}

proc external_diff_get_one_file {diffid filename diffdir} {
    global nullid nullid2 nullfile
    global worktree

    if {$diffid == $nullid} {
        set difffile [file join $worktree $filename]
	if {[file exists $difffile]} {
	    return $difffile
	}
	return $nullfile
    }
    if {$diffid == $nullid2} {
        set difffile [file join $diffdir "\[index\] [file tail $filename]"]
        return [save_file_from_commit :$filename $difffile index]
    }
    set difffile [file join $diffdir "\[$diffid\] [file tail $filename]"]
    return [save_file_from_commit $diffid:$filename $difffile \
	       "revision $diffid"]
}

proc external_diff {} {
    global nullid nullid2
    global flist_menu_file
    global diffids
    global extdifftool

    if {[llength $diffids] == 1} {
        # no reference commit given
        set diffidto [lindex $diffids 0]
        if {$diffidto eq $nullid} {
            # diffing working copy with index
            set diffidfrom $nullid2
        } elseif {$diffidto eq $nullid2} {
            # diffing index with HEAD
            set diffidfrom "HEAD"
        } else {
            # use first parent commit
            global parentlist selectedline
            set diffidfrom [lindex $parentlist $selectedline 0]
        }
    } else {
        set diffidfrom [lindex $diffids 0]
        set diffidto [lindex $diffids 1]
    }

    # make sure that several diffs wont collide
    set diffdir [gitknewtmpdir]
    if {$diffdir eq {}} return

    # gather files to diff
    set difffromfile [external_diff_get_one_file $diffidfrom $flist_menu_file $diffdir]
    set difftofile [external_diff_get_one_file $diffidto $flist_menu_file $diffdir]

    if {$difffromfile ne {} && $difftofile ne {}} {
        set cmd [list [shellsplit $extdifftool] $difffromfile $difftofile]
        if {[catch {set fl [open |$cmd r]} err]} {
            file delete -force $diffdir
            error_popup "$extdifftool: [mc "command failed:"] $err"
        } else {
            fconfigure $fl -blocking 0
            filerun $fl [list delete_at_eof $fl $diffdir]
        }
    }
}

proc find_hunk_blamespec {base line} {
    global ctext

    # Find and parse the hunk header
    set s_lix [$ctext search -backwards -regexp ^@@ "$line.0 lineend" $base.0]
    if {$s_lix eq {}} return

    set s_line [$ctext get $s_lix "$s_lix + 1 lines"]
    if {![regexp {^@@@*(( -\d+(,\d+)?)+) \+(\d+)(,\d+)? @@} $s_line \
	    s_line old_specs osz osz1 new_line nsz]} {
	return
    }

    # base lines for the parents
    set base_lines [list $new_line]
    foreach old_spec [lrange [split $old_specs " "] 1 end] {
	if {![regexp -- {-(\d+)(,\d+)?} $old_spec \
	        old_spec old_line osz]} {
	    return
	}
	lappend base_lines $old_line
    }

    # Now scan the lines to determine offset within the hunk
    set max_parent [expr {[llength $base_lines]-2}]
    set dline 0
    set s_lno [lindex [split $s_lix "."] 0]

    # Determine if the line is removed
    set chunk [$ctext get $line.0 "$line.1 + $max_parent chars"]
    if {[string match {[-+ ]*} $chunk]} {
	set removed_idx [string first "-" $chunk]
	# Choose a parent index
	if {$removed_idx >= 0} {
	    set parent $removed_idx
	} else {
	    set unchanged_idx [string first " " $chunk]
	    if {$unchanged_idx >= 0} {
		set parent $unchanged_idx
	    } else {
		# blame the current commit
		set parent -1
	    }
	}
	# then count other lines that belong to it
	for {set i $line} {[incr i -1] > $s_lno} {} {
	    set chunk [$ctext get $i.0 "$i.1 + $max_parent chars"]
	    # Determine if the line is removed
	    set removed_idx [string first "-" $chunk]
	    if {$parent >= 0} {
		set code [string index $chunk $parent]
		if {$code eq "-" || ($removed_idx < 0 && $code ne "+")} {
		    incr dline
		}
	    } else {
		if {$removed_idx < 0} {
		    incr dline
		}
	    }
	}
	incr parent
    } else {
	set parent 0
    }

    incr dline [lindex $base_lines $parent]
    return [list $parent $dline]
}

proc external_blame_diff {} {
    global currentid cmitmode
    global diff_menu_txtpos diff_menu_line
    global diff_menu_filebase flist_menu_file

    if {$cmitmode eq "tree"} {
	set parent_idx 0
	set line [expr {$diff_menu_line - $diff_menu_filebase}]
    } else {
	set hinfo [find_hunk_blamespec $diff_menu_filebase $diff_menu_line]
	if {$hinfo ne {}} {
	    set parent_idx [lindex $hinfo 0]
	    set line [lindex $hinfo 1]
	} else {
	    set parent_idx 0
	    set line 0
	}
    }

    external_blame $parent_idx $line
}

# Find the SHA1 ID of the blob for file $fname in the index
# at stage 0 or 2
proc index_sha1 {fname} {
    set f [open [list | git ls-files -s $fname] r]
    while {[gets $f line] >= 0} {
	set info [lindex [split $line "\t"] 0]
	set stage [lindex $info 2]
	if {$stage eq "0" || $stage eq "2"} {
	    close $f
	    return [lindex $info 1]
	}
    }
    close $f
    return {}
}

# Turn an absolute path into one relative to the current directory
proc make_relative {f} {
    if {[file pathtype $f] eq "relative"} {
	return $f
    }
    set elts [file split $f]
    set here [file split [pwd]]
    set ei 0
    set hi 0
    set res {}
    foreach d $here {
	if {$ei < $hi || $ei >= [llength $elts] || [lindex $elts $ei] ne $d} {
	    lappend res ".."
	} else {
	    incr ei
	}
	incr hi
    }
    set elts [concat $res [lrange $elts $ei end]]
    return [eval file join $elts]
}

proc external_blame {parent_idx {line {}}} {
    global flist_menu_file cdup
    global nullid nullid2
    global parentlist selectedline currentid

    if {$parent_idx > 0} {
	set base_commit [lindex $parentlist $selectedline [expr {$parent_idx-1}]]
    } else {
	set base_commit $currentid
    }

    if {$base_commit eq {} || $base_commit eq $nullid || $base_commit eq $nullid2} {
	error_popup [mc "No such commit"]
	return
    }

    set cmdline [list git gui blame]
    if {$line ne {} && $line > 1} {
	lappend cmdline "--line=$line"
    }
    set f [file join $cdup $flist_menu_file]
    # Unfortunately it seems git gui blame doesn't like
    # being given an absolute path...
    set f [make_relative $f]
    lappend cmdline $base_commit $f
    if {[catch {eval exec $cmdline &} err]} {
	error_popup "[mc "git gui blame: command failed:"] $err"
    }
}

proc show_line_source {} {
    global cmitmode currentid parents curview blamestuff blameinst
    global diff_menu_line diff_menu_filebase flist_menu_file
    global nullid nullid2 gitdir cdup

    set from_index {}
    if {$cmitmode eq "tree"} {
	set id $currentid
	set line [expr {$diff_menu_line - $diff_menu_filebase}]
    } else {
	set h [find_hunk_blamespec $diff_menu_filebase $diff_menu_line]
	if {$h eq {}} return
	set pi [lindex $h 0]
	if {$pi == 0} {
	    mark_ctext_line $diff_menu_line
	    return
	}
	incr pi -1
	if {$currentid eq $nullid} {
	    if {$pi > 0} {
		# must be a merge in progress...
		if {[catch {
		    # get the last line from .git/MERGE_HEAD
		    set f [open [file join $gitdir MERGE_HEAD] r]
		    set id [lindex [split [read $f] "\n"] end-1]
		    close $f
		} err]} {
		    error_popup [mc "Couldn't read merge head: %s" $err]
		    return
		}
	    } elseif {$parents($curview,$currentid) eq $nullid2} {
		# need to do the blame from the index
		if {[catch {
		    set from_index [index_sha1 $flist_menu_file]
		} err]} {
		    error_popup [mc "Error reading index: %s" $err]
		    return
		}
	    } else {
		set id $parents($curview,$currentid)
	    }
	} else {
	    set id [lindex $parents($curview,$currentid) $pi]
	}
	set line [lindex $h 1]
    }
    set blameargs {}
    if {$from_index ne {}} {
	lappend blameargs | git cat-file blob $from_index
    }
    lappend blameargs | git blame -p -L$line,+1
    if {$from_index ne {}} {
	lappend blameargs --contents -
    } else {
	lappend blameargs $id
    }
    lappend blameargs -- [file join $cdup $flist_menu_file]
    if {[catch {
	set f [open $blameargs r]
    } err]} {
	error_popup [mc "Couldn't start git blame: %s" $err]
	return
    }
    nowbusy blaming [mc "Searching"]
    fconfigure $f -blocking 0
    set i [reg_instance $f]
    set blamestuff($i) {}
    set blameinst $i
    filerun $f [list read_line_source $f $i]
}

proc stopblaming {} {
    global blameinst

    if {[info exists blameinst]} {
	stop_instance $blameinst
	unset blameinst
	notbusy blaming
    }
}

proc read_line_source {fd inst} {
    global blamestuff curview commfd blameinst nullid nullid2

    while {[gets $fd line] >= 0} {
	lappend blamestuff($inst) $line
    }
    if {![eof $fd]} {
	return 1
    }
    unset commfd($inst)
    unset blameinst
    notbusy blaming
    fconfigure $fd -blocking 1
    if {[catch {close $fd} err]} {
	error_popup [mc "Error running git blame: %s" $err]
	return 0
    }

    set fname {}
    set line [split [lindex $blamestuff($inst) 0] " "]
    set id [lindex $line 0]
    set lnum [lindex $line 1]
    if {[string length $id] == 40 && [string is xdigit $id] &&
	[string is digit -strict $lnum]} {
	# look for "filename" line
	foreach l $blamestuff($inst) {
	    if {[string match "filename *" $l]} {
		set fname [string range $l 9 end]
		break
	    }
	}
    }
    if {$fname ne {}} {
	# all looks good, select it
	if {$id eq $nullid} {
	    # blame uses all-zeroes to mean not committed,
	    # which would mean a change in the index
	    set id $nullid2
	}
	if {[commitinview $id $curview]} {
	    selectline [rowofcommit $id] 1 [list $fname $lnum] 1
	} else {
	    error_popup [mc "That line comes from commit %s, \
			     which is not in this view" [shortids $id]]
	}
    } else {
	puts "oops couldn't parse git blame output"
    }
    return 0
}

# delete $dir when we see eof on $f (presumably because the child has exited)
proc delete_at_eof {f dir} {
    while {[gets $f line] >= 0} {}
    if {[eof $f]} {
	if {[catch {close $f} err]} {
	    error_popup "[mc "External diff viewer failed:"] $err"
	}
	file delete -force $dir
	return 0
    }
    return 1
}

# Functions for adding and removing shell-type quoting

proc shellquote {str} {
    if {![string match "*\['\"\\ \t]*" $str]} {
	return $str
    }
    if {![string match "*\['\"\\]*" $str]} {
	return "\"$str\""
    }
    if {![string match "*'*" $str]} {
	return "'$str'"
    }
    return "\"[string map {\" \\\" \\ \\\\} $str]\""
}

proc shellarglist {l} {
    set str {}
    foreach a $l {
	if {$str ne {}} {
	    append str " "
	}
	append str [shellquote $a]
    }
    return $str
}

proc shelldequote {str} {
    set ret {}
    set used -1
    while {1} {
	incr used
	if {![regexp -start $used -indices "\['\"\\\\ \t]" $str first]} {
	    append ret [string range $str $used end]
	    set used [string length $str]
	    break
	}
	set first [lindex $first 0]
	set ch [string index $str $first]
	if {$first > $used} {
	    append ret [string range $str $used [expr {$first - 1}]]
	    set used $first
	}
	if {$ch eq " " || $ch eq "\t"} break
	incr used
	if {$ch eq "'"} {
	    set first [string first "'" $str $used]
	    if {$first < 0} {
		error "unmatched single-quote"
	    }
	    append ret [string range $str $used [expr {$first - 1}]]
	    set used $first
	    continue
	}
	if {$ch eq "\\"} {
	    if {$used >= [string length $str]} {
		error "trailing backslash"
	    }
	    append ret [string index $str $used]
	    continue
	}
	# here ch == "\""
	while {1} {
	    if {![regexp -start $used -indices "\[\"\\\\]" $str first]} {
		error "unmatched double-quote"
	    }
	    set first [lindex $first 0]
	    set ch [string index $str $first]
	    if {$first > $used} {
		append ret [string range $str $used [expr {$first - 1}]]
		set used $first
	    }
	    if {$ch eq "\""} break
	    incr used
	    append ret [string index $str $used]
	    incr used
	}
    }
    return [list $used $ret]
}

proc shellsplit {str} {
    set l {}
    while {1} {
	set str [string trimleft $str]
	if {$str eq {}} break
	set dq [shelldequote $str]
	set n [lindex $dq 0]
	set word [lindex $dq 1]
	set str [string range $str $n end]
	lappend l $word
    }
    return $l
}

# Code to implement multiple views

proc newview {ishighlight} {
    global nextviewnum newviewname newishighlight
    global revtreeargs viewargscmd newviewopts curview

    set newishighlight $ishighlight
    set top .gitkview
    if {[winfo exists $top]} {
	raise $top
	return
    }
    decode_view_opts $nextviewnum $revtreeargs
    set newviewname($nextviewnum) "[mc "View"] $nextviewnum"
    set newviewopts($nextviewnum,perm) 0
    set newviewopts($nextviewnum,cmd)  $viewargscmd($curview)
    vieweditor $top $nextviewnum [mc "Gitk view definition"]
}

set known_view_options {
    {perm      b    .  {}               {mc "Remember this view"}}
    {reflabel  l    +  {}               {mc "References (space separated list):"}}
    {refs      t15  .. {}               {mc "Branches & tags:"}}
    {allrefs   b    *. "--all"          {mc "All refs"}}
    {branches  b    .  "--branches"     {mc "All (local) branches"}}
    {tags      b    .  "--tags"         {mc "All tags"}}
    {remotes   b    .  "--remotes"      {mc "All remote-tracking branches"}}
    {commitlbl l    +  {}               {mc "Commit Info (regular expressions):"}}
    {author    t15  .. "--author=*"     {mc "Author:"}}
    {committer t15  .  "--committer=*"  {mc "Committer:"}}
    {loginfo   t15  .. "--grep=*"       {mc "Commit Message:"}}
    {allmatch  b    .. "--all-match"    {mc "Matches all Commit Info criteria"}}
    {changes_l l    +  {}               {mc "Changes to Files:"}}
    {pickaxe_s r0   .  {}               {mc "Fixed String"}}
    {pickaxe_t r1   .  "--pickaxe-regex"  {mc "Regular Expression"}}
    {pickaxe   t15  .. "-S*"            {mc "Search string:"}}
    {datelabel l    +  {}               {mc "Commit Dates (\"2 weeks ago\", \"2009-03-17 15:27:38\", \"March 17, 2009 15:27:38\"):"}}
    {since     t15  ..  {"--since=*" "--after=*"}  {mc "Since:"}}
    {until     t15  .   {"--until=*" "--before=*"} {mc "Until:"}}
    {limit_lbl l    +  {}               {mc "Limit and/or skip a number of revisions (positive integer):"}}
    {limit     t10  *. "--max-count=*"  {mc "Number to show:"}}
    {skip      t10  .  "--skip=*"       {mc "Number to skip:"}}
    {misc_lbl  l    +  {}               {mc "Miscellaneous options:"}}
    {dorder    b    *. {"--date-order" "-d"}      {mc "Strictly sort by date"}}
    {lright    b    .  "--left-right"   {mc "Mark branch sides"}}
    {first     b    .  "--first-parent" {mc "Limit to first parent"}}
    {smplhst   b    .  "--simplify-by-decoration"   {mc "Simple history"}}
    {args      t50  *. {}               {mc "Additional arguments to git log:"}}
    {allpaths  path +  {}               {mc "Enter files and directories to include, one per line:"}}
    {cmd       t50= +  {}               {mc "Command to generate more commits to include:"}}
    }

# Convert $newviewopts($n, ...) into args for git log.
proc encode_view_opts {n} {
    global known_view_options newviewopts

    set rargs [list]
    foreach opt $known_view_options {
	set patterns [lindex $opt 3]
	if {$patterns eq {}} continue
	set pattern [lindex $patterns 0]

	if {[lindex $opt 1] eq "b"} {
	    set val $newviewopts($n,[lindex $opt 0])
	    if {$val} {
		lappend rargs $pattern
	    }
	} elseif {[regexp {^r(\d+)$} [lindex $opt 1] type value]} {
	    regexp {^(.*_)} [lindex $opt 0] uselessvar button_id
	    set val $newviewopts($n,$button_id)
	    if {$val eq $value} {
		lappend rargs $pattern
	    }
	} else {
	    set val $newviewopts($n,[lindex $opt 0])
	    set val [string trim $val]
	    if {$val ne {}} {
		set pfix [string range $pattern 0 end-1]
		lappend rargs $pfix$val
	    }
	}
    }
    set rargs [concat $rargs [shellsplit $newviewopts($n,refs)]]
    return [concat $rargs [shellsplit $newviewopts($n,args)]]
}

# Fill $newviewopts($n, ...) based on args for git log.
proc decode_view_opts {n view_args} {
    global known_view_options newviewopts

    foreach opt $known_view_options {
	set id [lindex $opt 0]
	if {[lindex $opt 1] eq "b"} {
	    # Checkboxes
	    set val 0
        } elseif {[regexp {^r(\d+)$} [lindex $opt 1]]} {
	    # Radiobuttons
	    regexp {^(.*_)} $id uselessvar id
	    set val 0
	} else {
	    # Text fields
	    set val {}
	}
	set newviewopts($n,$id) $val
    }
    set oargs [list]
    set refargs [list]
    foreach arg $view_args {
	if {[regexp -- {^-([0-9]+)$} $arg arg cnt]
	    && ![info exists found(limit)]} {
	    set newviewopts($n,limit) $cnt
	    set found(limit) 1
	    continue
	}
	catch { unset val }
	foreach opt $known_view_options {
	    set id [lindex $opt 0]
	    if {[info exists found($id)]} continue
	    foreach pattern [lindex $opt 3] {
		if {![string match $pattern $arg]} continue
		if {[lindex $opt 1] eq "b"} {
		    # Check buttons
		    set val 1
		} elseif {[regexp {^r(\d+)$} [lindex $opt 1] match num]} {
		    # Radio buttons
		    regexp {^(.*_)} $id uselessvar id
		    set val $num
		} else {
		    # Text input fields
		    set size [string length $pattern]
		    set val [string range $arg [expr {$size-1}] end]
		}
		set newviewopts($n,$id) $val
		set found($id) 1
		break
	    }
	    if {[info exists val]} break
	}
	if {[info exists val]} continue
	if {[regexp {^-} $arg]} {
	    lappend oargs $arg
	} else {
	    lappend refargs $arg
	}
    }
    set newviewopts($n,refs) [shellarglist $refargs]
    set newviewopts($n,args) [shellarglist $oargs]
}

proc edit_or_newview {} {
    global curview

    if {$curview > 0} {
	editview
    } else {
	newview 0
    }
}

proc editview {} {
    global curview
    global viewname viewperm newviewname newviewopts
    global viewargs viewargscmd

    set top .gitkvedit-$curview
    if {[winfo exists $top]} {
	raise $top
	return
    }
    decode_view_opts $curview $viewargs($curview)
    set newviewname($curview)      $viewname($curview)
    set newviewopts($curview,perm) $viewperm($curview)
    set newviewopts($curview,cmd)  $viewargscmd($curview)
    vieweditor $top $curview "[mc "Gitk: edit view"] $viewname($curview)"
}

proc vieweditor {top n title} {
    global newviewname newviewopts viewfiles bgcolor
    global known_view_options NS

    ttk_toplevel $top
    wm title $top [concat $title [mc "-- criteria for selecting revisions"]]
    make_transient $top .

    # View name
    ${NS}::frame $top.nfr
    ${NS}::label $top.nl -text [mc "View Name"]
    ${NS}::entry $top.name -width 20 -textvariable newviewname($n)
    pack $top.nfr -in $top -fill x -pady 5 -padx 3
    pack $top.nl -in $top.nfr -side left -padx {0 5}
    pack $top.name -in $top.nfr -side left -padx {0 25}

    # View options
    set cframe $top.nfr
    set cexpand 0
    set cnt 0
    foreach opt $known_view_options {
	set id [lindex $opt 0]
	set type [lindex $opt 1]
	set flags [lindex $opt 2]
	set title [eval [lindex $opt 4]]
	set lxpad 0

	if {$flags eq "+" || $flags eq "*"} {
	    set cframe $top.fr$cnt
	    incr cnt
	    ${NS}::frame $cframe
	    pack $cframe -in $top -fill x -pady 3 -padx 3
	    set cexpand [expr {$flags eq "*"}]
        } elseif {$flags eq ".." || $flags eq "*."} {
	    set cframe $top.fr$cnt
	    incr cnt
	    ${NS}::frame $cframe
	    pack $cframe -in $top -fill x -pady 3 -padx [list 15 3]
	    set cexpand [expr {$flags eq "*."}]
	} else {
	    set lxpad 5
	}

	if {$type eq "l"} {
            ${NS}::label $cframe.l_$id -text $title
            pack $cframe.l_$id -in $cframe -side left -pady [list 3 0] -anchor w
	} elseif {$type eq "b"} {
	    ${NS}::checkbutton $cframe.c_$id -text $title -variable newviewopts($n,$id)
	    pack $cframe.c_$id -in $cframe -side left \
		-padx [list $lxpad 0] -expand $cexpand -anchor w
	} elseif {[regexp {^r(\d+)$} $type type sz]} {
	    regexp {^(.*_)} $id uselessvar button_id
	    ${NS}::radiobutton $cframe.c_$id -text $title -variable newviewopts($n,$button_id) -value $sz
	    pack $cframe.c_$id -in $cframe -side left \
		-padx [list $lxpad 0] -expand $cexpand -anchor w
	} elseif {[regexp {^t(\d+)$} $type type sz]} {
	    ${NS}::label $cframe.l_$id -text $title
	    ${NS}::entry $cframe.e_$id -width $sz -background $bgcolor \
		-textvariable newviewopts($n,$id)
	    pack $cframe.l_$id -in $cframe -side left -padx [list $lxpad 0]
	    pack $cframe.e_$id -in $cframe -side left -expand 1 -fill x
	} elseif {[regexp {^t(\d+)=$} $type type sz]} {
	    ${NS}::label $cframe.l_$id -text $title
	    ${NS}::entry $cframe.e_$id -width $sz -background $bgcolor \
		-textvariable newviewopts($n,$id)
	    pack $cframe.l_$id -in $cframe -side top -pady [list 3 0] -anchor w
	    pack $cframe.e_$id -in $cframe -side top -fill x
	} elseif {$type eq "path"} {
	    ${NS}::label $top.l -text $title
	    pack $top.l -in $top -side top -pady [list 3 0] -anchor w -padx 3
	    text $top.t -width 40 -height 5 -background $bgcolor
	    if {[info exists viewfiles($n)]} {
		foreach f $viewfiles($n) {
		    $top.t insert end $f
		    $top.t insert end "\n"
		}
		$top.t delete {end - 1c} end
		$top.t mark set insert 0.0
	    }
	    pack $top.t -in $top -side top -pady [list 0 5] -fill both -expand 1 -padx 3
	}
    }

    ${NS}::frame $top.buts
    ${NS}::button $top.buts.ok -text [mc "OK"] -command [list newviewok $top $n]
    ${NS}::button $top.buts.apply -text [mc "Apply (F5)"] -command [list newviewok $top $n 1]
    ${NS}::button $top.buts.can -text [mc "Cancel"] -command [list destroy $top]
    bind $top <Control-Return> [list newviewok $top $n]
    bind $top <F5> [list newviewok $top $n 1]
    bind $top <Escape> [list destroy $top]
    grid $top.buts.ok $top.buts.apply $top.buts.can
    grid columnconfigure $top.buts 0 -weight 1 -uniform a
    grid columnconfigure $top.buts 1 -weight 1 -uniform a
    grid columnconfigure $top.buts 2 -weight 1 -uniform a
    pack $top.buts -in $top -side top -fill x
    focus $top.t
}

proc doviewmenu {m first cmd op argv} {
    set nmenu [$m index end]
    for {set i $first} {$i <= $nmenu} {incr i} {
	if {[$m entrycget $i -command] eq $cmd} {
	    eval $m $op $i $argv
	    break
	}
    }
}

proc allviewmenus {n op args} {
    # global viewhlmenu

    doviewmenu .bar.view 5 [list showview $n] $op $args
    # doviewmenu $viewhlmenu 1 [list addvhighlight $n] $op $args
}

proc newviewok {top n {apply 0}} {
    global nextviewnum newviewperm newviewname newishighlight
    global viewname viewfiles viewperm selectedview curview
    global viewargs viewargscmd newviewopts viewhlmenu

    if {[catch {
	set newargs [encode_view_opts $n]
    } err]} {
	error_popup "[mc "Error in commit selection arguments:"] $err" $top
	return
    }
    set files {}
    foreach f [split [$top.t get 0.0 end] "\n"] {
	set ft [string trim $f]
	if {$ft ne {}} {
	    lappend files $ft
	}
    }
    if {![info exists viewfiles($n)]} {
	# creating a new view
	incr nextviewnum
	set viewname($n) $newviewname($n)
	set viewperm($n) $newviewopts($n,perm)
	set viewfiles($n) $files
	set viewargs($n) $newargs
	set viewargscmd($n) $newviewopts($n,cmd)
	addviewmenu $n
	if {!$newishighlight} {
	    run showview $n
	} else {
	    run addvhighlight $n
	}
    } else {
	# editing an existing view
	set viewperm($n) $newviewopts($n,perm)
	if {$newviewname($n) ne $viewname($n)} {
	    set viewname($n) $newviewname($n)
	    doviewmenu .bar.view 5 [list showview $n] \
		entryconf [list -label $viewname($n)]
	    # doviewmenu $viewhlmenu 1 [list addvhighlight $n] \
		# entryconf [list -label $viewname($n) -value $viewname($n)]
	}
	if {$files ne $viewfiles($n) || $newargs ne $viewargs($n) || \
		$newviewopts($n,cmd) ne $viewargscmd($n)} {
	    set viewfiles($n) $files
	    set viewargs($n) $newargs
	    set viewargscmd($n) $newviewopts($n,cmd)
	    if {$curview == $n} {
		run reloadcommits
	    }
	}
    }
    if {$apply} return
    catch {destroy $top}
}

proc delview {} {
    global curview viewperm hlview selectedhlview

    if {$curview == 0} return
    if {[info exists hlview] && $hlview == $curview} {
	set selectedhlview [mc "None"]
	unset hlview
    }
    allviewmenus $curview delete
    set viewperm($curview) 0
    showview 0
}

proc addviewmenu {n} {
    global viewname viewhlmenu

    .bar.view add radiobutton -label $viewname($n) \
	-command [list showview $n] -variable selectedview -value $n
    #$viewhlmenu add radiobutton -label $viewname($n) \
    #	-command [list addvhighlight $n] -variable selectedhlview
}

proc showview {n} {
    global curview cached_commitrow ordertok
    global displayorder parentlist rowidlist rowisopt rowfinal
    global colormap rowtextx nextcolor canvxmax
    global numcommits viewcomplete
    global selectedline currentid canv canvy0
    global treediffs
    global pending_select mainheadid
    global commitidx
    global selectedview
    global hlview selectedhlview commitinterest

    if {$n == $curview} return
    set selid {}
    set ymax [lindex [$canv cget -scrollregion] 3]
    set span [$canv yview]
    set ytop [expr {[lindex $span 0] * $ymax}]
    set ybot [expr {[lindex $span 1] * $ymax}]
    set yscreen [expr {($ybot - $ytop) / 2}]
    if {$selectedline ne {}} {
	set selid $currentid
	set y [yc $selectedline]
	if {$ytop < $y && $y < $ybot} {
	    set yscreen [expr {$y - $ytop}]
	}
    } elseif {[info exists pending_select]} {
	set selid $pending_select
	unset pending_select
    }
    unselectline
    normalline
    catch {unset treediffs}
    clear_display
    if {[info exists hlview] && $hlview == $n} {
	unset hlview
	set selectedhlview [mc "None"]
    }
    catch {unset commitinterest}
    catch {unset cached_commitrow}
    catch {unset ordertok}

    set curview $n
    set selectedview $n
    .bar.view entryconf [mca "Edit view..."] -state [expr {$n == 0? "disabled": "normal"}]
    .bar.view entryconf [mca "Delete view"] -state [expr {$n == 0? "disabled": "normal"}]

    run refill_reflist
    if {![info exists viewcomplete($n)]} {
	getcommits $selid
	return
    }

    set displayorder {}
    set parentlist {}
    set rowidlist {}
    set rowisopt {}
    set rowfinal {}
    set numcommits $commitidx($n)

    catch {unset colormap}
    catch {unset rowtextx}
    set nextcolor 0
    set canvxmax [$canv cget -width]
    set curview $n
    set row 0
    setcanvscroll
    set yf 0
    set row {}
    if {$selid ne {} && [commitinview $selid $n]} {
	set row [rowofcommit $selid]
	# try to get the selected row in the same position on the screen
	set ymax [lindex [$canv cget -scrollregion] 3]
	set ytop [expr {[yc $row] - $yscreen}]
	if {$ytop < 0} {
	    set ytop 0
	}
	set yf [expr {$ytop * 1.0 / $ymax}]
    }
    allcanvs yview moveto $yf
    drawvisible
    if {$row ne {}} {
	selectline $row 0
    } elseif {!$viewcomplete($n)} {
	reset_pending_select $selid
    } else {
	reset_pending_select {}

	if {[commitinview $pending_select $curview]} {
	    selectline [rowofcommit $pending_select] 1
	} else {
	    set row [first_real_row]
	    if {$row < $numcommits} {
		selectline $row 0
	    }
	}
    }
    if {!$viewcomplete($n)} {
	if {$numcommits == 0} {
	    show_status [mc "Reading commits..."]
	}
    } elseif {$numcommits == 0} {
	show_status [mc "No commits selected"]
    }
}

# Stuff relating to the highlighting facility

proc ishighlighted {id} {
    global vhighlights fhighlights nhighlights rhighlights

    if {[info exists nhighlights($id)] && $nhighlights($id) > 0} {
	return $nhighlights($id)
    }
    if {[info exists vhighlights($id)] && $vhighlights($id) > 0} {
	return $vhighlights($id)
    }
    if {[info exists fhighlights($id)] && $fhighlights($id) > 0} {
	return $fhighlights($id)
    }
    if {[info exists rhighlights($id)] && $rhighlights($id) > 0} {
	return $rhighlights($id)
    }
    return 0
}

proc bolden {id font} {
    global canv linehtag currentid boldids need_redisplay markedid

    # need_redisplay = 1 means the display is stale and about to be redrawn
    if {$need_redisplay} return
    lappend boldids $id
    $canv itemconf $linehtag($id) -font $font
    if {[info exists currentid] && $id eq $currentid} {
	$canv delete secsel
	set t [eval $canv create rect [$canv bbox $linehtag($id)] \
		   -outline {{}} -tags secsel \
		   -fill [$canv cget -selectbackground]]
	$canv lower $t
    }
    if {[info exists markedid] && $id eq $markedid} {
	make_idmark $id
    }
}

proc bolden_name {id font} {
    global canv2 linentag currentid boldnameids need_redisplay

    if {$need_redisplay} return
    lappend boldnameids $id
    $canv2 itemconf $linentag($id) -font $font
    if {[info exists currentid] && $id eq $currentid} {
	$canv2 delete secsel
	set t [eval $canv2 create rect [$canv2 bbox $linentag($id)] \
		   -outline {{}} -tags secsel \
		   -fill [$canv2 cget -selectbackground]]
	$canv2 lower $t
    }
}

proc unbolden {} {
    global boldids

    set stillbold {}
    foreach id $boldids {
	if {![ishighlighted $id]} {
	    bolden $id mainfont
	} else {
	    lappend stillbold $id
	}
    }
    set boldids $stillbold
}

proc addvhighlight {n} {
    global hlview viewcomplete curview vhl_done commitidx

    if {[info exists hlview]} {
	delvhighlight
    }
    set hlview $n
    if {$n != $curview && ![info exists viewcomplete($n)]} {
	start_rev_list $n
    }
    set vhl_done $commitidx($hlview)
    if {$vhl_done > 0} {
	drawvisible
    }
}

proc delvhighlight {} {
    global hlview vhighlights

    if {![info exists hlview]} return
    unset hlview
    catch {unset vhighlights}
    unbolden
}

proc vhighlightmore {} {
    global hlview vhl_done commitidx vhighlights curview

    set max $commitidx($hlview)
    set vr [visiblerows]
    set r0 [lindex $vr 0]
    set r1 [lindex $vr 1]
    for {set i $vhl_done} {$i < $max} {incr i} {
	set id [commitonrow $i $hlview]
	if {[commitinview $id $curview]} {
	    set row [rowofcommit $id]
	    if {$r0 <= $row && $row <= $r1} {
		if {![highlighted $row]} {
		    bolden $id mainfontbold
		}
		set vhighlights($id) 1
	    }
	}
    }
    set vhl_done $max
    return 0
}

proc askvhighlight {row id} {
    global hlview vhighlights iddrawn

    if {[commitinview $id $hlview]} {
	if {[info exists iddrawn($id)] && ![ishighlighted $id]} {
	    bolden $id mainfontbold
	}
	set vhighlights($id) 1
    } else {
	set vhighlights($id) 0
    }
}

proc hfiles_change {} {
    global highlight_files filehighlight fhighlights fh_serial
    global highlight_paths

    if {[info exists filehighlight]} {
	# delete previous highlights
	catch {close $filehighlight}
	unset filehighlight
	catch {unset fhighlights}
	unbolden
	unhighlight_filelist
    }
    set highlight_paths {}
    after cancel do_file_hl $fh_serial
    incr fh_serial
    if {$highlight_files ne {}} {
	after 300 do_file_hl $fh_serial
    }
}

proc gdttype_change {name ix op} {
    global gdttype highlight_files findstring findpattern

    stopfinding
    if {$findstring ne {}} {
	if {$gdttype eq [mc "containing:"]} {
	    if {$highlight_files ne {}} {
		set highlight_files {}
		hfiles_change
	    }
	    findcom_change
	} else {
	    if {$findpattern ne {}} {
		set findpattern {}
		findcom_change
	    }
	    set highlight_files $findstring
	    hfiles_change
	}
	drawvisible
    }
    # enable/disable findtype/findloc menus too
}

proc find_change {name ix op} {
    global gdttype findstring highlight_files

    stopfinding
    if {$gdttype eq [mc "containing:"]} {
	findcom_change
    } else {
	if {$highlight_files ne $findstring} {
	    set highlight_files $findstring
	    hfiles_change
	}
    }
    drawvisible
}

proc findcom_change args {
    global nhighlights boldnameids
    global findpattern findtype findstring gdttype

    stopfinding
    # delete previous highlights, if any
    foreach id $boldnameids {
	bolden_name $id mainfont
    }
    set boldnameids {}
    catch {unset nhighlights}
    unbolden
    unmarkmatches
    if {$gdttype ne [mc "containing:"] || $findstring eq {}} {
	set findpattern {}
    } elseif {$findtype eq [mc "Regexp"]} {
	set findpattern $findstring
    } else {
	set e [string map {"*" "\\*" "?" "\\?" "\[" "\\\[" "\\" "\\\\"} \
		   $findstring]
	set findpattern "*$e*"
    }
}

proc makepatterns {l} {
    set ret {}
    foreach e $l {
	set ee [string map {"*" "\\*" "?" "\\?" "\[" "\\\[" "\\" "\\\\"} $e]
	if {[string index $ee end] eq "/"} {
	    lappend ret "$ee*"
	} else {
	    lappend ret $ee
	    lappend ret "$ee/*"
	}
    }
    return $ret
}

proc do_file_hl {serial} {
    global highlight_files filehighlight highlight_paths gdttype fhl_list
    global cdup findtype

    if {$gdttype eq [mc "touching paths:"]} {
	# If "exact" match then convert backslashes to forward slashes.
	# Most useful to support Windows-flavoured file paths.
	if {$findtype eq [mc "Exact"]} {
	    set highlight_files [string map {"\\" "/"} $highlight_files]
	}
	if {[catch {set paths [shellsplit $highlight_files]}]} return
	set highlight_paths [makepatterns $paths]
	highlight_filelist
	set relative_paths {}
	foreach path $paths {
	    lappend relative_paths [file join $cdup $path]
	}
	set gdtargs [concat -- $relative_paths]
    } elseif {$gdttype eq [mc "adding/removing string:"]} {
	set gdtargs [list "-S$highlight_files"]
    } elseif {$gdttype eq [mc "changing lines matching:"]} {
	set gdtargs [list "-G$highlight_files"]
    } else {
	# must be "containing:", i.e. we're searching commit info
	return
    }
    set cmd [concat | git diff-tree -r -s --stdin $gdtargs]
    set filehighlight [open $cmd r+]
    fconfigure $filehighlight -blocking 0
    filerun $filehighlight readfhighlight
    set fhl_list {}
    drawvisible
    flushhighlights
}

proc flushhighlights {} {
    global filehighlight fhl_list

    if {[info exists filehighlight]} {
	lappend fhl_list {}
	puts $filehighlight ""
	flush $filehighlight
    }
}

proc askfilehighlight {row id} {
    global filehighlight fhighlights fhl_list

    lappend fhl_list $id
    set fhighlights($id) -1
    puts $filehighlight $id
}

proc readfhighlight {} {
    global filehighlight fhighlights curview iddrawn
    global fhl_list find_dirn

    if {![info exists filehighlight]} {
	return 0
    }
    set nr 0
    while {[incr nr] <= 100 && [gets $filehighlight line] >= 0} {
	set line [string trim $line]
	set i [lsearch -exact $fhl_list $line]
	if {$i < 0} continue
	for {set j 0} {$j < $i} {incr j} {
	    set id [lindex $fhl_list $j]
	    set fhighlights($id) 0
	}
	set fhl_list [lrange $fhl_list [expr {$i+1}] end]
	if {$line eq {}} continue
	if {![commitinview $line $curview]} continue
	if {[info exists iddrawn($line)] && ![ishighlighted $line]} {
	    bolden $line mainfontbold
	}
	set fhighlights($line) 1
    }
    if {[eof $filehighlight]} {
	# strange...
	puts "oops, git diff-tree died"
	catch {close $filehighlight}
	unset filehighlight
	return 0
    }
    if {[info exists find_dirn]} {
	run findmore
    }
    return 1
}

proc doesmatch {f} {
    global findtype findpattern

    if {$findtype eq [mc "Regexp"]} {
	return [regexp $findpattern $f]
    } elseif {$findtype eq [mc "IgnCase"]} {
	return [string match -nocase $findpattern $f]
    } else {
	return [string match $findpattern $f]
    }
}

proc askfindhighlight {row id} {
    global nhighlights commitinfo iddrawn
    global findloc
    global markingmatches

    if {![info exists commitinfo($id)]} {
	getcommit $id
    }
    set info $commitinfo($id)
    set isbold 0
    set fldtypes [list [mc Headline] [mc Author] "" [mc Committer] "" [mc Comments]]
    foreach f $info ty $fldtypes {
	if {$ty eq ""} continue
	if {($findloc eq [mc "All fields"] || $findloc eq $ty) &&
	    [doesmatch $f]} {
	    if {$ty eq [mc "Author"]} {
		set isbold 2
		break
	    }
	    set isbold 1
	}
    }
    if {$isbold && [info exists iddrawn($id)]} {
	if {![ishighlighted $id]} {
	    bolden $id mainfontbold
	    if {$isbold > 1} {
		bolden_name $id mainfontbold
	    }
	}
	if {$markingmatches} {
	    markrowmatches $row $id
	}
    }
    set nhighlights($id) $isbold
}

proc markrowmatches {row id} {
    global canv canv2 linehtag linentag commitinfo findloc

    set headline [lindex $commitinfo($id) 0]
    set author [lindex $commitinfo($id) 1]
    $canv delete match$row
    $canv2 delete match$row
    if {$findloc eq [mc "All fields"] || $findloc eq [mc "Headline"]} {
	set m [findmatches $headline]
	if {$m ne {}} {
	    markmatches $canv $row $headline $linehtag($id) $m \
		[$canv itemcget $linehtag($id) -font] $row
	}
    }
    if {$findloc eq [mc "All fields"] || $findloc eq [mc "Author"]} {
	set m [findmatches $author]
	if {$m ne {}} {
	    markmatches $canv2 $row $author $linentag($id) $m \
		[$canv2 itemcget $linentag($id) -font] $row
	}
    }
}

proc vrel_change {name ix op} {
    global highlight_related

    rhighlight_none
    if {$highlight_related ne [mc "None"]} {
	run drawvisible
    }
}

# prepare for testing whether commits are descendents or ancestors of a
proc rhighlight_sel {a} {
    global descendent desc_todo ancestor anc_todo
    global highlight_related

    catch {unset descendent}
    set desc_todo [list $a]
    catch {unset ancestor}
    set anc_todo [list $a]
    if {$highlight_related ne [mc "None"]} {
	rhighlight_none
	run drawvisible
    }
}

proc rhighlight_none {} {
    global rhighlights

    catch {unset rhighlights}
    unbolden
}

proc is_descendent {a} {
    global curview children descendent desc_todo

    set v $curview
    set la [rowofcommit $a]
    set todo $desc_todo
    set leftover {}
    set done 0
    for {set i 0} {$i < [llength $todo]} {incr i} {
	set do [lindex $todo $i]
	if {[rowofcommit $do] < $la} {
	    lappend leftover $do
	    continue
	}
	foreach nk $children($v,$do) {
	    if {![info exists descendent($nk)]} {
		set descendent($nk) 1
		lappend todo $nk
		if {$nk eq $a} {
		    set done 1
		}
	    }
	}
	if {$done} {
	    set desc_todo [concat $leftover [lrange $todo [expr {$i+1}] end]]
	    return
	}
    }
    set descendent($a) 0
    set desc_todo $leftover
}

proc is_ancestor {a} {
    global curview parents ancestor anc_todo

    set v $curview
    set la [rowofcommit $a]
    set todo $anc_todo
    set leftover {}
    set done 0
    for {set i 0} {$i < [llength $todo]} {incr i} {
	set do [lindex $todo $i]
	if {![commitinview $do $v] || [rowofcommit $do] > $la} {
	    lappend leftover $do
	    continue
	}
	foreach np $parents($v,$do) {
	    if {![info exists ancestor($np)]} {
		set ancestor($np) 1
		lappend todo $np
		if {$np eq $a} {
		    set done 1
		}
	    }
	}
	if {$done} {
	    set anc_todo [concat $leftover [lrange $todo [expr {$i+1}] end]]
	    return
	}
    }
    set ancestor($a) 0
    set anc_todo $leftover
}

proc askrelhighlight {row id} {
    global descendent highlight_related iddrawn rhighlights
    global selectedline ancestor

    if {$selectedline eq {}} return
    set isbold 0
    if {$highlight_related eq [mc "Descendant"] ||
	$highlight_related eq [mc "Not descendant"]} {
	if {![info exists descendent($id)]} {
	    is_descendent $id
	}
	if {$descendent($id) == ($highlight_related eq [mc "Descendant"])} {
	    set isbold 1
	}
    } elseif {$highlight_related eq [mc "Ancestor"] ||
	      $highlight_related eq [mc "Not ancestor"]} {
	if {![info exists ancestor($id)]} {
	    is_ancestor $id
	}
	if {$ancestor($id) == ($highlight_related eq [mc "Ancestor"])} {
	    set isbold 1
	}
    }
    if {[info exists iddrawn($id)]} {
	if {$isbold && ![ishighlighted $id]} {
	    bolden $id mainfontbold
	}
    }
    set rhighlights($id) $isbold
}

# Graph layout functions

proc shortids {ids} {
    set res {}
    foreach id $ids {
	if {[llength $id] > 1} {
	    lappend res [shortids $id]
	} elseif {[regexp {^[0-9a-f]{40}$} $id]} {
	    lappend res [string range $id 0 7]
	} else {
	    lappend res $id
	}
    }
    return $res
}

proc ntimes {n o} {
    set ret {}
    set o [list $o]
    for {set mask 1} {$mask <= $n} {incr mask $mask} {
	if {($n & $mask) != 0} {
	    set ret [concat $ret $o]
	}
	set o [concat $o $o]
    }
    return $ret
}

proc ordertoken {id} {
    global ordertok curview varcid varcstart varctok curview parents children
    global nullid nullid2

    if {[info exists ordertok($id)]} {
	return $ordertok($id)
    }
    set origid $id
    set todo {}
    while {1} {
	if {[info exists varcid($curview,$id)]} {
	    set a $varcid($curview,$id)
	    set p [lindex $varcstart($curview) $a]
	} else {
	    set p [lindex $children($curview,$id) 0]
	}
	if {[info exists ordertok($p)]} {
	    set tok $ordertok($p)
	    break
	}
	set id [first_real_child $curview,$p]
	if {$id eq {}} {
	    # it's a root
	    set tok [lindex $varctok($curview) $varcid($curview,$p)]
	    break
	}
	if {[llength $parents($curview,$id)] == 1} {
	    lappend todo [list $p {}]
	} else {
	    set j [lsearch -exact $parents($curview,$id) $p]
	    if {$j < 0} {
		puts "oops didn't find [shortids $p] in parents of [shortids $id]"
	    }
	    lappend todo [list $p [strrep $j]]
	}
    }
    for {set i [llength $todo]} {[incr i -1] >= 0} {} {
	set p [lindex $todo $i 0]
	append tok [lindex $todo $i 1]
	set ordertok($p) $tok
    }
    set ordertok($origid) $tok
    return $tok
}

# Work out where id should go in idlist so that order-token
# values increase from left to right
proc idcol {idlist id {i 0}} {
    set t [ordertoken $id]
    if {$i < 0} {
	set i 0
    }
    if {$i >= [llength $idlist] || $t < [ordertoken [lindex $idlist $i]]} {
	if {$i > [llength $idlist]} {
	    set i [llength $idlist]
	}
	while {[incr i -1] >= 0 && $t < [ordertoken [lindex $idlist $i]]} {}
	incr i
    } else {
	if {$t > [ordertoken [lindex $idlist $i]]} {
	    while {[incr i] < [llength $idlist] &&
		   $t >= [ordertoken [lindex $idlist $i]]} {}
	}
    }
    return $i
}

proc initlayout {} {
    global rowidlist rowisopt rowfinal displayorder parentlist
    global numcommits canvxmax canv
    global nextcolor
    global colormap rowtextx

    set numcommits 0
    set displayorder {}
    set parentlist {}
    set nextcolor 0
    set rowidlist {}
    set rowisopt {}
    set rowfinal {}
    set canvxmax [$canv cget -width]
    catch {unset colormap}
    catch {unset rowtextx}
    setcanvscroll
}

proc setcanvscroll {} {
    global canv canv2 canv3 numcommits linespc canvxmax canvy0
    global lastscrollset lastscrollrows

    set ymax [expr {$canvy0 + ($numcommits - 0.5) * $linespc + 2}]
    $canv conf -scrollregion [list 0 0 $canvxmax $ymax]
    $canv2 conf -scrollregion [list 0 0 0 $ymax]
    $canv3 conf -scrollregion [list 0 0 0 $ymax]
    set lastscrollset [clock clicks -milliseconds]
    set lastscrollrows $numcommits
}

proc visiblerows {} {
    global canv numcommits linespc

    set ymax [lindex [$canv cget -scrollregion] 3]
    if {$ymax eq {} || $ymax == 0} return
    set f [$canv yview]
    set y0 [expr {int([lindex $f 0] * $ymax)}]
    set r0 [expr {int(($y0 - 3) / $linespc) - 1}]
    if {$r0 < 0} {
	set r0 0
    }
    set y1 [expr {int([lindex $f 1] * $ymax)}]
    set r1 [expr {int(($y1 - 3) / $linespc) + 1}]
    if {$r1 >= $numcommits} {
	set r1 [expr {$numcommits - 1}]
    }
    return [list $r0 $r1]
}

proc layoutmore {} {
    global commitidx viewcomplete curview
    global numcommits pending_select curview
    global lastscrollset lastscrollrows

    if {$lastscrollrows < 100 || $viewcomplete($curview) ||
	[clock clicks -milliseconds] - $lastscrollset > 500} {
	setcanvscroll
    }
    if {[info exists pending_select] &&
	[commitinview $pending_select $curview]} {
	update
	selectline [rowofcommit $pending_select] 1
    }
    drawvisible
}

# With path limiting, we mightn't get the actual HEAD commit,
# so ask git rev-list what is the first ancestor of HEAD that
# touches a file in the path limit.
proc get_viewmainhead {view} {
    global viewmainheadid vfilelimit viewinstances mainheadid

    catch {
	set rfd [open [concat | git rev-list -1 $mainheadid \
			   -- $vfilelimit($view)] r]
	set j [reg_instance $rfd]
	lappend viewinstances($view) $j
	fconfigure $rfd -blocking 0
	filerun $rfd [list getviewhead $rfd $j $view]
	set viewmainheadid($curview) {}
    }
}

# git rev-list should give us just 1 line to use as viewmainheadid($view)
proc getviewhead {fd inst view} {
    global viewmainheadid commfd curview viewinstances showlocalchanges

    set id {}
    if {[gets $fd line] < 0} {
	if {![eof $fd]} {
	    return 1
	}
    } elseif {[string length $line] == 40 && [string is xdigit $line]} {
	set id $line
    }
    set viewmainheadid($view) $id
    close $fd
    unset commfd($inst)
    set i [lsearch -exact $viewinstances($view) $inst]
    if {$i >= 0} {
	set viewinstances($view) [lreplace $viewinstances($view) $i $i]
    }
    if {$showlocalchanges && $id ne {} && $view == $curview} {
	doshowlocalchanges
    }
    return 0
}

proc doshowlocalchanges {} {
    global curview viewmainheadid

    if {$viewmainheadid($curview) eq {}} return
    if {[commitinview $viewmainheadid($curview) $curview]} {
	dodiffindex
    } else {
	interestedin $viewmainheadid($curview) dodiffindex
    }
}

proc dohidelocalchanges {} {
    global nullid nullid2 lserial curview

    if {[commitinview $nullid $curview]} {
	removefakerow $nullid
    }
    if {[commitinview $nullid2 $curview]} {
	removefakerow $nullid2
    }
    incr lserial
}

# spawn off a process to do git diff-index --cached HEAD
proc dodiffindex {} {
    global lserial showlocalchanges vfilelimit curview
    global hasworktree git_version

    if {!$showlocalchanges || !$hasworktree} return
    incr lserial
    if {[package vcompare $git_version "1.7.2"] >= 0} {
	set cmd "|git diff-index --cached --ignore-submodules=dirty HEAD"
    } else {
	set cmd "|git diff-index --cached HEAD"
    }
    if {$vfilelimit($curview) ne {}} {
	set cmd [concat $cmd -- $vfilelimit($curview)]
    }
    set fd [open $cmd r]
    fconfigure $fd -blocking 0
    set i [reg_instance $fd]
    filerun $fd [list readdiffindex $fd $lserial $i]
}

proc readdiffindex {fd serial inst} {
    global viewmainheadid nullid nullid2 curview commitinfo commitdata lserial
    global vfilelimit

    set isdiff 1
    if {[gets $fd line] < 0} {
	if {![eof $fd]} {
	    return 1
	}
	set isdiff 0
    }
    # we only need to see one line and we don't really care what it says...
    stop_instance $inst

    if {$serial != $lserial} {
	return 0
    }

    # now see if there are any local changes not checked in to the index
    set cmd "|git diff-files"
    if {$vfilelimit($curview) ne {}} {
	set cmd [concat $cmd -- $vfilelimit($curview)]
    }
    set fd [open $cmd r]
    fconfigure $fd -blocking 0
    set i [reg_instance $fd]
    filerun $fd [list readdifffiles $fd $serial $i]

    if {$isdiff && ![commitinview $nullid2 $curview]} {
	# add the line for the changes in the index to the graph
	set hl [mc "Local changes checked in to index but not committed"]
	set commitinfo($nullid2) [list  $hl {} {} {} {} "    $hl\n"]
	set commitdata($nullid2) "\n    $hl\n"
	if {[commitinview $nullid $curview]} {
	    removefakerow $nullid
	}
	insertfakerow $nullid2 $viewmainheadid($curview)
    } elseif {!$isdiff && [commitinview $nullid2 $curview]} {
	if {[commitinview $nullid $curview]} {
	    removefakerow $nullid
	}
	removefakerow $nullid2
    }
    return 0
}

proc readdifffiles {fd serial inst} {
    global viewmainheadid nullid nullid2 curview
    global commitinfo commitdata lserial

    set isdiff 1
    if {[gets $fd line] < 0} {
	if {![eof $fd]} {
	    return 1
	}
	set isdiff 0
    }
    # we only need to see one line and we don't really care what it says...
    stop_instance $inst

    if {$serial != $lserial} {
	return 0
    }

    if {$isdiff && ![commitinview $nullid $curview]} {
	# add the line for the local diff to the graph
	set hl [mc "Local uncommitted changes, not checked in to index"]
	set commitinfo($nullid) [list  $hl {} {} {} {} "    $hl\n"]
	set commitdata($nullid) "\n    $hl\n"
	if {[commitinview $nullid2 $curview]} {
	    set p $nullid2
	} else {
	    set p $viewmainheadid($curview)
	}
	insertfakerow $nullid $p
    } elseif {!$isdiff && [commitinview $nullid $curview]} {
	removefakerow $nullid
    }
    return 0
}

proc nextuse {id row} {
    global curview children

    if {[info exists children($curview,$id)]} {
	foreach kid $children($curview,$id) {
	    if {![commitinview $kid $curview]} {
		return -1
	    }
	    if {[rowofcommit $kid] > $row} {
		return [rowofcommit $kid]
	    }
	}
    }
    if {[commitinview $id $curview]} {
	return [rowofcommit $id]
    }
    return -1
}

proc prevuse {id row} {
    global curview children

    set ret -1
    if {[info exists children($curview,$id)]} {
	foreach kid $children($curview,$id) {
	    if {![commitinview $kid $curview]} break
	    if {[rowofcommit $kid] < $row} {
		set ret [rowofcommit $kid]
	    }
	}
    }
    return $ret
}

proc make_idlist {row} {
    global displayorder parentlist uparrowlen downarrowlen mingaplen
    global commitidx curview children

    set r [expr {$row - $mingaplen - $downarrowlen - 1}]
    if {$r < 0} {
	set r 0
    }
    set ra [expr {$row - $downarrowlen}]
    if {$ra < 0} {
	set ra 0
    }
    set rb [expr {$row + $uparrowlen}]
    if {$rb > $commitidx($curview)} {
	set rb $commitidx($curview)
    }
    make_disporder $r [expr {$rb + 1}]
    set ids {}
    for {} {$r < $ra} {incr r} {
	set nextid [lindex $displayorder [expr {$r + 1}]]
	foreach p [lindex $parentlist $r] {
	    if {$p eq $nextid} continue
	    set rn [nextuse $p $r]
	    if {$rn >= $row &&
		$rn <= $r + $downarrowlen + $mingaplen + $uparrowlen} {
		lappend ids [list [ordertoken $p] $p]
	    }
	}
    }
    for {} {$r < $row} {incr r} {
	set nextid [lindex $displayorder [expr {$r + 1}]]
	foreach p [lindex $parentlist $r] {
	    if {$p eq $nextid} continue
	    set rn [nextuse $p $r]
	    if {$rn < 0 || $rn >= $row} {
		lappend ids [list [ordertoken $p] $p]
	    }
	}
    }
    set id [lindex $displayorder $row]
    lappend ids [list [ordertoken $id] $id]
    while {$r < $rb} {
	foreach p [lindex $parentlist $r] {
	    set firstkid [lindex $children($curview,$p) 0]
	    if {[rowofcommit $firstkid] < $row} {
		lappend ids [list [ordertoken $p] $p]
	    }
	}
	incr r
	set id [lindex $displayorder $r]
	if {$id ne {}} {
	    set firstkid [lindex $children($curview,$id) 0]
	    if {$firstkid ne {} && [rowofcommit $firstkid] < $row} {
		lappend ids [list [ordertoken $id] $id]
	    }
	}
    }
    set idlist {}
    foreach idx [lsort -unique $ids] {
	lappend idlist [lindex $idx 1]
    }
    return $idlist
}

proc rowsequal {a b} {
    while {[set i [lsearch -exact $a {}]] >= 0} {
	set a [lreplace $a $i $i]
    }
    while {[set i [lsearch -exact $b {}]] >= 0} {
	set b [lreplace $b $i $i]
    }
    return [expr {$a eq $b}]
}

proc makeupline {id row rend col} {
    global rowidlist uparrowlen downarrowlen mingaplen

    for {set r $rend} {1} {set r $rstart} {
	set rstart [prevuse $id $r]
	if {$rstart < 0} return
	if {$rstart < $row} break
    }
    if {$rstart + $uparrowlen + $mingaplen + $downarrowlen < $rend} {
	set rstart [expr {$rend - $uparrowlen - 1}]
    }
    for {set r $rstart} {[incr r] <= $row} {} {
	set idlist [lindex $rowidlist $r]
	if {$idlist ne {} && [lsearch -exact $idlist $id] < 0} {
	    set col [idcol $idlist $id $col]
	    lset rowidlist $r [linsert $idlist $col $id]
	    changedrow $r
	}
    }
}

proc layoutrows {row endrow} {
    global rowidlist rowisopt rowfinal displayorder
    global uparrowlen downarrowlen maxwidth mingaplen
    global children parentlist
    global commitidx viewcomplete curview

    make_disporder [expr {$row - 1}] [expr {$endrow + $uparrowlen}]
    set idlist {}
    if {$row > 0} {
	set rm1 [expr {$row - 1}]
	foreach id [lindex $rowidlist $rm1] {
	    if {$id ne {}} {
		lappend idlist $id
	    }
	}
	set final [lindex $rowfinal $rm1]
    }
    for {} {$row < $endrow} {incr row} {
	set rm1 [expr {$row - 1}]
	if {$rm1 < 0 || $idlist eq {}} {
	    set idlist [make_idlist $row]
	    set final 1
	} else {
	    set id [lindex $displayorder $rm1]
	    set col [lsearch -exact $idlist $id]
	    set idlist [lreplace $idlist $col $col]
	    foreach p [lindex $parentlist $rm1] {
		if {[lsearch -exact $idlist $p] < 0} {
		    set col [idcol $idlist $p $col]
		    set idlist [linsert $idlist $col $p]
		    # if not the first child, we have to insert a line going up
		    if {$id ne [lindex $children($curview,$p) 0]} {
			makeupline $p $rm1 $row $col
		    }
		}
	    }
	    set id [lindex $displayorder $row]
	    if {$row > $downarrowlen} {
		set termrow [expr {$row - $downarrowlen - 1}]
		foreach p [lindex $parentlist $termrow] {
		    set i [lsearch -exact $idlist $p]
		    if {$i < 0} continue
		    set nr [nextuse $p $termrow]
		    if {$nr < 0 || $nr >= $row + $mingaplen + $uparrowlen} {
			set idlist [lreplace $idlist $i $i]
		    }
		}
	    }
	    set col [lsearch -exact $idlist $id]
	    if {$col < 0} {
		set col [idcol $idlist $id]
		set idlist [linsert $idlist $col $id]
		if {$children($curview,$id) ne {}} {
		    makeupline $id $rm1 $row $col
		}
	    }
	    set r [expr {$row + $uparrowlen - 1}]
	    if {$r < $commitidx($curview)} {
		set x $col
		foreach p [lindex $parentlist $r] {
		    if {[lsearch -exact $idlist $p] >= 0} continue
		    set fk [lindex $children($curview,$p) 0]
		    if {[rowofcommit $fk] < $row} {
			set x [idcol $idlist $p $x]
			set idlist [linsert $idlist $x $p]
		    }
		}
		if {[incr r] < $commitidx($curview)} {
		    set p [lindex $displayorder $r]
		    if {[lsearch -exact $idlist $p] < 0} {
			set fk [lindex $children($curview,$p) 0]
			if {$fk ne {} && [rowofcommit $fk] < $row} {
			    set x [idcol $idlist $p $x]
			    set idlist [linsert $idlist $x $p]
			}
		    }
		}
	    }
	}
	if {$final && !$viewcomplete($curview) &&
	    $row + $uparrowlen + $mingaplen + $downarrowlen
		>= $commitidx($curview)} {
	    set final 0
	}
	set l [llength $rowidlist]
	if {$row == $l} {
	    lappend rowidlist $idlist
	    lappend rowisopt 0
	    lappend rowfinal $final
	} elseif {$row < $l} {
	    if {![rowsequal $idlist [lindex $rowidlist $row]]} {
		lset rowidlist $row $idlist
		changedrow $row
	    }
	    lset rowfinal $row $final
	} else {
	    set pad [ntimes [expr {$row - $l}] {}]
	    set rowidlist [concat $rowidlist $pad]
	    lappend rowidlist $idlist
	    set rowfinal [concat $rowfinal $pad]
	    lappend rowfinal $final
	    set rowisopt [concat $rowisopt [ntimes [expr {$row - $l + 1}] 0]]
	}
    }
    return $row
}

proc changedrow {row} {
    global displayorder iddrawn rowisopt need_redisplay

    set l [llength $rowisopt]
    if {$row < $l} {
	lset rowisopt $row 0
	if {$row + 1 < $l} {
	    lset rowisopt [expr {$row + 1}] 0
	    if {$row + 2 < $l} {
		lset rowisopt [expr {$row + 2}] 0
	    }
	}
    }
    set id [lindex $displayorder $row]
    if {[info exists iddrawn($id)]} {
	set need_redisplay 1
    }
}

proc insert_pad {row col npad} {
    global rowidlist

    set pad [ntimes $npad {}]
    set idlist [lindex $rowidlist $row]
    set bef [lrange $idlist 0 [expr {$col - 1}]]
    set aft [lrange $idlist $col end]
    set i [lsearch -exact $aft {}]
    if {$i > 0} {
	set aft [lreplace $aft $i $i]
    }
    lset rowidlist $row [concat $bef $pad $aft]
    changedrow $row
}

proc optimize_rows {row col endrow} {
    global rowidlist rowisopt displayorder curview children

    if {$row < 1} {
	set row 1
    }
    for {} {$row < $endrow} {incr row; set col 0} {
	if {[lindex $rowisopt $row]} continue
	set haspad 0
	set y0 [expr {$row - 1}]
	set ym [expr {$row - 2}]
	set idlist [lindex $rowidlist $row]
	set previdlist [lindex $rowidlist $y0]
	if {$idlist eq {} || $previdlist eq {}} continue
	if {$ym >= 0} {
	    set pprevidlist [lindex $rowidlist $ym]
	    if {$pprevidlist eq {}} continue
	} else {
	    set pprevidlist {}
	}
	set x0 -1
	set xm -1
	for {} {$col < [llength $idlist]} {incr col} {
	    set id [lindex $idlist $col]
	    if {[lindex $previdlist $col] eq $id} continue
	    if {$id eq {}} {
		set haspad 1
		continue
	    }
	    set x0 [lsearch -exact $previdlist $id]
	    if {$x0 < 0} continue
	    set z [expr {$x0 - $col}]
	    set isarrow 0
	    set z0 {}
	    if {$ym >= 0} {
		set xm [lsearch -exact $pprevidlist $id]
		if {$xm >= 0} {
		    set z0 [expr {$xm - $x0}]
		}
	    }
	    if {$z0 eq {}} {
		# if row y0 is the first child of $id then it's not an arrow
		if {[lindex $children($curview,$id) 0] ne
		    [lindex $displayorder $y0]} {
		    set isarrow 1
		}
	    }
	    if {!$isarrow && $id ne [lindex $displayorder $row] &&
		[lsearch -exact [lindex $rowidlist [expr {$row+1}]] $id] < 0} {
		set isarrow 1
	    }
	    # Looking at lines from this row to the previous row,
	    # make them go straight up if they end in an arrow on
	    # the previous row; otherwise make them go straight up
	    # or at 45 degrees.
	    if {$z < -1 || ($z < 0 && $isarrow)} {
		# Line currently goes left too much;
		# insert pads in the previous row, then optimize it
		set npad [expr {-1 - $z + $isarrow}]
		insert_pad $y0 $x0 $npad
		if {$y0 > 0} {
		    optimize_rows $y0 $x0 $row
		}
		set previdlist [lindex $rowidlist $y0]
		set x0 [lsearch -exact $previdlist $id]
		set z [expr {$x0 - $col}]
		if {$z0 ne {}} {
		    set pprevidlist [lindex $rowidlist $ym]
		    set xm [lsearch -exact $pprevidlist $id]
		    set z0 [expr {$xm - $x0}]
		}
	    } elseif {$z > 1 || ($z > 0 && $isarrow)} {
		# Line currently goes right too much;
		# insert pads in this line
		set npad [expr {$z - 1 + $isarrow}]
		insert_pad $row $col $npad
		set idlist [lindex $rowidlist $row]
		incr col $npad
		set z [expr {$x0 - $col}]
		set haspad 1
	    }
	    if {$z0 eq {} && !$isarrow && $ym >= 0} {
		# this line links to its first child on row $row-2
		set id [lindex $displayorder $ym]
		set xc [lsearch -exact $pprevidlist $id]
		if {$xc >= 0} {
		    set z0 [expr {$xc - $x0}]
		}
	    }
	    # avoid lines jigging left then immediately right
	    if {$z0 ne {} && $z < 0 && $z0 > 0} {
		insert_pad $y0 $x0 1
		incr x0
		optimize_rows $y0 $x0 $row
		set previdlist [lindex $rowidlist $y0]
	    }
	}
	if {!$haspad} {
	    # Find the first column that doesn't have a line going right
	    for {set col [llength $idlist]} {[incr col -1] >= 0} {} {
		set id [lindex $idlist $col]
		if {$id eq {}} break
		set x0 [lsearch -exact $previdlist $id]
		if {$x0 < 0} {
		    # check if this is the link to the first child
		    set kid [lindex $displayorder $y0]
		    if {[lindex $children($curview,$id) 0] eq $kid} {
			# it is, work out offset to child
			set x0 [lsearch -exact $previdlist $kid]
		    }
		}
		if {$x0 <= $col} break
	    }
	    # Insert a pad at that column as long as it has a line and
	    # isn't the last column
	    if {$x0 >= 0 && [incr col] < [llength $idlist]} {
		set idlist [linsert $idlist $col {}]
		lset rowidlist $row $idlist
		changedrow $row
	    }
	}
    }
}

proc xc {row col} {
    global canvx0 linespc
    return [expr {$canvx0 + $col * $linespc}]
}

proc yc {row} {
    global canvy0 linespc
    return [expr {$canvy0 + $row * $linespc}]
}

proc linewidth {id} {
    global thickerline lthickness

    set wid $lthickness
    if {[info exists thickerline] && $id eq $thickerline} {
	set wid [expr {2 * $lthickness}]
    }
    return $wid
}

proc rowranges {id} {
    global curview children uparrowlen downarrowlen
    global rowidlist

    set kids $children($curview,$id)
    if {$kids eq {}} {
	return {}
    }
    set ret {}
    lappend kids $id
    foreach child $kids {
	if {![commitinview $child $curview]} break
	set row [rowofcommit $child]
	if {![info exists prev]} {
	    lappend ret [expr {$row + 1}]
	} else {
	    if {$row <= $prevrow} {
		puts "oops children of [shortids $id] out of order [shortids $child] $row <= [shortids $prev] $prevrow"
	    }
	    # see if the line extends the whole way from prevrow to row
	    if {$row > $prevrow + $uparrowlen + $downarrowlen &&
		[lsearch -exact [lindex $rowidlist \
			    [expr {int(($row + $prevrow) / 2)}]] $id] < 0} {
		# it doesn't, see where it ends
		set r [expr {$prevrow + $downarrowlen}]
		if {[lsearch -exact [lindex $rowidlist $r] $id] < 0} {
		    while {[incr r -1] > $prevrow &&
			   [lsearch -exact [lindex $rowidlist $r] $id] < 0} {}
		} else {
		    while {[incr r] <= $row &&
			   [lsearch -exact [lindex $rowidlist $r] $id] >= 0} {}
		    incr r -1
		}
		lappend ret $r
		# see where it starts up again
		set r [expr {$row - $uparrowlen}]
		if {[lsearch -exact [lindex $rowidlist $r] $id] < 0} {
		    while {[incr r] < $row &&
			   [lsearch -exact [lindex $rowidlist $r] $id] < 0} {}
		} else {
		    while {[incr r -1] >= $prevrow &&
			   [lsearch -exact [lindex $rowidlist $r] $id] >= 0} {}
		    incr r
		}
		lappend ret $r
	    }
	}
	if {$child eq $id} {
	    lappend ret $row
	}
	set prev $child
	set prevrow $row
    }
    return $ret
}

proc drawlineseg {id row endrow arrowlow} {
    global rowidlist displayorder iddrawn linesegs
    global canv colormap linespc curview maxlinelen parentlist

    set cols [list [lsearch -exact [lindex $rowidlist $row] $id]]
    set le [expr {$row + 1}]
    set arrowhigh 1
    while {1} {
	set c [lsearch -exact [lindex $rowidlist $le] $id]
	if {$c < 0} {
	    incr le -1
	    break
	}
	lappend cols $c
	set x [lindex $displayorder $le]
	if {$x eq $id} {
	    set arrowhigh 0
	    break
	}
	if {[info exists iddrawn($x)] || $le == $endrow} {
	    set c [lsearch -exact [lindex $rowidlist [expr {$le+1}]] $id]
	    if {$c >= 0} {
		lappend cols $c
		set arrowhigh 0
	    }
	    break
	}
	incr le
    }
    if {$le <= $row} {
	return $row
    }

    set lines {}
    set i 0
    set joinhigh 0
    if {[info exists linesegs($id)]} {
	set lines $linesegs($id)
	foreach li $lines {
	    set r0 [lindex $li 0]
	    if {$r0 > $row} {
		if {$r0 == $le && [lindex $li 1] - $row <= $maxlinelen} {
		    set joinhigh 1
		}
		break
	    }
	    incr i
	}
    }
    set joinlow 0
    if {$i > 0} {
	set li [lindex $lines [expr {$i-1}]]
	set r1 [lindex $li 1]
	if {$r1 == $row && $le - [lindex $li 0] <= $maxlinelen} {
	    set joinlow 1
	}
    }

    set x [lindex $cols [expr {$le - $row}]]
    set xp [lindex $cols [expr {$le - 1 - $row}]]
    set dir [expr {$xp - $x}]
    if {$joinhigh} {
	set ith [lindex $lines $i 2]
	set coords [$canv coords $ith]
	set ah [$canv itemcget $ith -arrow]
	set arrowhigh [expr {$ah eq "first" || $ah eq "both"}]
	set x2 [lindex $cols [expr {$le + 1 - $row}]]
	if {$x2 ne {} && $x - $x2 == $dir} {
	    set coords [lrange $coords 0 end-2]
	}
    } else {
	set coords [list [xc $le $x] [yc $le]]
    }
    if {$joinlow} {
	set itl [lindex $lines [expr {$i-1}] 2]
	set al [$canv itemcget $itl -arrow]
	set arrowlow [expr {$al eq "last" || $al eq "both"}]
    } elseif {$arrowlow} {
	if {[lsearch -exact [lindex $rowidlist [expr {$row-1}]] $id] >= 0 ||
	    [lsearch -exact [lindex $parentlist [expr {$row-1}]] $id] >= 0} {
	    set arrowlow 0
	}
    }
    set arrow [lindex {none first last both} [expr {$arrowhigh + 2*$arrowlow}]]
    for {set y $le} {[incr y -1] > $row} {} {
	set x $xp
	set xp [lindex $cols [expr {$y - 1 - $row}]]
	set ndir [expr {$xp - $x}]
	if {$dir != $ndir || $xp < 0} {
	    lappend coords [xc $y $x] [yc $y]
	}
	set dir $ndir
    }
    if {!$joinlow} {
	if {$xp < 0} {
	    # join parent line to first child
	    set ch [lindex $displayorder $row]
	    set xc [lsearch -exact [lindex $rowidlist $row] $ch]
	    if {$xc < 0} {
		puts "oops: drawlineseg: child $ch not on row $row"
	    } elseif {$xc != $x} {
		if {($arrowhigh && $le == $row + 1) || $dir == 0} {
		    set d [expr {int(0.5 * $linespc)}]
		    set x1 [xc $row $x]
		    if {$xc < $x} {
			set x2 [expr {$x1 - $d}]
		    } else {
			set x2 [expr {$x1 + $d}]
		    }
		    set y2 [yc $row]
		    set y1 [expr {$y2 + $d}]
		    lappend coords $x1 $y1 $x2 $y2
		} elseif {$xc < $x - 1} {
		    lappend coords [xc $row [expr {$x-1}]] [yc $row]
		} elseif {$xc > $x + 1} {
		    lappend coords [xc $row [expr {$x+1}]] [yc $row]
		}
		set x $xc
	    }
	    lappend coords [xc $row $x] [yc $row]
	} else {
	    set xn [xc $row $xp]
	    set yn [yc $row]
	    lappend coords $xn $yn
	}
	if {!$joinhigh} {
	    assigncolor $id
	    set t [$canv create line $coords -width [linewidth $id] \
		       -fill $colormap($id) -tags lines.$id -arrow $arrow]
	    $canv lower $t
	    bindline $t $id
	    set lines [linsert $lines $i [list $row $le $t]]
	} else {
	    $canv coords $ith $coords
	    if {$arrow ne $ah} {
		$canv itemconf $ith -arrow $arrow
	    }
	    lset lines $i 0 $row
	}
    } else {
	set xo [lsearch -exact [lindex $rowidlist [expr {$row - 1}]] $id]
	set ndir [expr {$xo - $xp}]
	set clow [$canv coords $itl]
	if {$dir == $ndir} {
	    set clow [lrange $clow 2 end]
	}
	set coords [concat $coords $clow]
	if {!$joinhigh} {
	    lset lines [expr {$i-1}] 1 $le
	} else {
	    # coalesce two pieces
	    $canv delete $ith
	    set b [lindex $lines [expr {$i-1}] 0]
	    set e [lindex $lines $i 1]
	    set lines [lreplace $lines [expr {$i-1}] $i [list $b $e $itl]]
	}
	$canv coords $itl $coords
	if {$arrow ne $al} {
	    $canv itemconf $itl -arrow $arrow
	}
    }

    set linesegs($id) $lines
    return $le
}

proc drawparentlinks {id row} {
    global rowidlist canv colormap curview parentlist
    global idpos linespc

    set rowids [lindex $rowidlist $row]
    set col [lsearch -exact $rowids $id]
    if {$col < 0} return
    set olds [lindex $parentlist $row]
    set row2 [expr {$row + 1}]
    set x [xc $row $col]
    set y [yc $row]
    set y2 [yc $row2]
    set d [expr {int(0.5 * $linespc)}]
    set ymid [expr {$y + $d}]
    set ids [lindex $rowidlist $row2]
    # rmx = right-most X coord used
    set rmx 0
    foreach p $olds {
	set i [lsearch -exact $ids $p]
	if {$i < 0} {
	    puts "oops, parent $p of $id not in list"
	    continue
	}
	set x2 [xc $row2 $i]
	if {$x2 > $rmx} {
	    set rmx $x2
	}
	set j [lsearch -exact $rowids $p]
	if {$j < 0} {
	    # drawlineseg will do this one for us
	    continue
	}
	assigncolor $p
	# should handle duplicated parents here...
	set coords [list $x $y]
	if {$i != $col} {
	    # if attaching to a vertical segment, draw a smaller
	    # slant for visual distinctness
	    if {$i == $j} {
		if {$i < $col} {
		    lappend coords [expr {$x2 + $d}] $y $x2 $ymid
		} else {
		    lappend coords [expr {$x2 - $d}] $y $x2 $ymid
		}
	    } elseif {$i < $col && $i < $j} {
		# segment slants towards us already
		lappend coords [xc $row $j] $y
	    } else {
		if {$i < $col - 1} {
		    lappend coords [expr {$x2 + $linespc}] $y
		} elseif {$i > $col + 1} {
		    lappend coords [expr {$x2 - $linespc}] $y
		}
		lappend coords $x2 $y2
	    }
	} else {
	    lappend coords $x2 $y2
	}
	set t [$canv create line $coords -width [linewidth $p] \
		   -fill $colormap($p) -tags lines.$p]
	$canv lower $t
	bindline $t $p
    }
    if {$rmx > [lindex $idpos($id) 1]} {
	lset idpos($id) 1 $rmx
	redrawtags $id
    }
}

proc drawlines {id} {
    global canv

    $canv itemconf lines.$id -width [linewidth $id]
}

proc drawcmittext {id row col} {
    global linespc canv canv2 canv3 fgcolor curview
    global cmitlisted commitinfo rowidlist parentlist
    global rowtextx idpos idtags idheads idotherrefs
    global linehtag linentag linedtag selectedline
    global canvxmax boldids boldnameids fgcolor markedid
    global mainheadid nullid nullid2 circleitem circlecolors ctxbut
    global mainheadcirclecolor workingfilescirclecolor indexcirclecolor
    global circleoutlinecolor

    # listed is 0 for boundary, 1 for normal, 2 for negative, 3 for left, 4 for right
    set listed $cmitlisted($curview,$id)
    if {$id eq $nullid} {
	set ofill $workingfilescirclecolor
    } elseif {$id eq $nullid2} {
	set ofill $indexcirclecolor
    } elseif {$id eq $mainheadid} {
	set ofill $mainheadcirclecolor
    } else {
	set ofill [lindex $circlecolors $listed]
    }
    set x [xc $row $col]
    set y [yc $row]
    set orad [expr {$linespc / 3}]
    if {$listed <= 2} {
	set t [$canv create oval [expr {$x - $orad}] [expr {$y - $orad}] \
		   [expr {$x + $orad - 1}] [expr {$y + $orad - 1}] \
		   -fill $ofill -outline $circleoutlinecolor -width 1 -tags circle]
    } elseif {$listed == 3} {
	# triangle pointing left for left-side commits
	set t [$canv create polygon \
		   [expr {$x - $orad}] $y \
		   [expr {$x + $orad - 1}] [expr {$y - $orad}] \
		   [expr {$x + $orad - 1}] [expr {$y + $orad - 1}] \
		   -fill $ofill -outline $circleoutlinecolor -width 1 -tags circle]
    } else {
	# triangle pointing right for right-side commits
	set t [$canv create polygon \
		   [expr {$x + $orad - 1}] $y \
		   [expr {$x - $orad}] [expr {$y - $orad}] \
		   [expr {$x - $orad}] [expr {$y + $orad - 1}] \
		   -fill $ofill -outline $circleoutlinecolor -width 1 -tags circle]
    }
    set circleitem($row) $t
    $canv raise $t
    $canv bind $t <1> {selcanvline {} %x %y}
    set rmx [llength [lindex $rowidlist $row]]
    set olds [lindex $parentlist $row]
    if {$olds ne {}} {
	set nextids [lindex $rowidlist [expr {$row + 1}]]
	foreach p $olds {
	    set i [lsearch -exact $nextids $p]
	    if {$i > $rmx} {
		set rmx $i
	    }
	}
    }
    set xt [xc $row $rmx]
    set rowtextx($row) $xt
    set idpos($id) [list $x $xt $y]
    if {[info exists idtags($id)] || [info exists idheads($id)]
	|| [info exists idotherrefs($id)]} {
	set xt [drawtags $id $x $xt $y]
    }
    if {[lindex $commitinfo($id) 6] > 0} {
	set xt [drawnotesign $xt $y]
    }
    set headline [lindex $commitinfo($id) 0]
    set name [lindex $commitinfo($id) 1]
    set date [lindex $commitinfo($id) 2]
    set date [formatdate $date]
    set font mainfont
    set nfont mainfont
    set isbold [ishighlighted $id]
    if {$isbold > 0} {
	lappend boldids $id
	set font mainfontbold
	if {$isbold > 1} {
	    lappend boldnameids $id
	    set nfont mainfontbold
	}
    }
    set linehtag($id) [$canv create text $xt $y -anchor w -fill $fgcolor \
			   -text $headline -font $font -tags text]
    $canv bind $linehtag($id) $ctxbut "rowmenu %X %Y $id"
    set linentag($id) [$canv2 create text 3 $y -anchor w -fill $fgcolor \
			   -text $name -font $nfont -tags text]
    set linedtag($id) [$canv3 create text 3 $y -anchor w -fill $fgcolor \
			   -text $date -font mainfont -tags text]
    if {$selectedline == $row} {
	make_secsel $id
    }
    if {[info exists markedid] && $markedid eq $id} {
	make_idmark $id
    }
    set xr [expr {$xt + [font measure $font $headline]}]
    if {$xr > $canvxmax} {
	set canvxmax $xr
	setcanvscroll
    }
}

proc drawcmitrow {row} {
    global displayorder rowidlist nrows_drawn
    global iddrawn markingmatches
    global commitinfo numcommits
    global filehighlight fhighlights findpattern nhighlights
    global hlview vhighlights
    global highlight_related rhighlights

    if {$row >= $numcommits} return

    set id [lindex $displayorder $row]
    if {[info exists hlview] && ![info exists vhighlights($id)]} {
	askvhighlight $row $id
    }
    if {[info exists filehighlight] && ![info exists fhighlights($id)]} {
	askfilehighlight $row $id
    }
    if {$findpattern ne {} && ![info exists nhighlights($id)]} {
	askfindhighlight $row $id
    }
    if {$highlight_related ne [mc "None"] && ![info exists rhighlights($id)]} {
	askrelhighlight $row $id
    }
    if {![info exists iddrawn($id)]} {
	set col [lsearch -exact [lindex $rowidlist $row] $id]
	if {$col < 0} {
	    puts "oops, row $row id $id not in list"
	    return
	}
	if {![info exists commitinfo($id)]} {
	    getcommit $id
	}
	assigncolor $id
	drawcmittext $id $row $col
	set iddrawn($id) 1
	incr nrows_drawn
    }
    if {$markingmatches} {
	markrowmatches $row $id
    }
}

proc drawcommits {row {endrow {}}} {
    global numcommits iddrawn displayorder curview need_redisplay
    global parentlist rowidlist rowfinal uparrowlen downarrowlen nrows_drawn

    if {$row < 0} {
	set row 0
    }
    if {$endrow eq {}} {
	set endrow $row
    }
    if {$endrow >= $numcommits} {
	set endrow [expr {$numcommits - 1}]
    }

    set rl1 [expr {$row - $downarrowlen - 3}]
    if {$rl1 < 0} {
	set rl1 0
    }
    set ro1 [expr {$row - 3}]
    if {$ro1 < 0} {
	set ro1 0
    }
    set r2 [expr {$endrow + $uparrowlen + 3}]
    if {$r2 > $numcommits} {
	set r2 $numcommits
    }
    for {set r $rl1} {$r < $r2} {incr r} {
	if {[lindex $rowidlist $r] ne {} && [lindex $rowfinal $r]} {
	    if {$rl1 < $r} {
		layoutrows $rl1 $r
	    }
	    set rl1 [expr {$r + 1}]
	}
    }
    if {$rl1 < $r} {
	layoutrows $rl1 $r
    }
    optimize_rows $ro1 0 $r2
    if {$need_redisplay || $nrows_drawn > 2000} {
	clear_display
    }

    # make the lines join to already-drawn rows either side
    set r [expr {$row - 1}]
    if {$r < 0 || ![info exists iddrawn([lindex $displayorder $r])]} {
	set r $row
    }
    set er [expr {$endrow + 1}]
    if {$er >= $numcommits ||
	![info exists iddrawn([lindex $displayorder $er])]} {
	set er $endrow
    }
    for {} {$r <= $er} {incr r} {
	set id [lindex $displayorder $r]
	set wasdrawn [info exists iddrawn($id)]
	drawcmitrow $r
	if {$r == $er} break
	set nextid [lindex $displayorder [expr {$r + 1}]]
	if {$wasdrawn && [info exists iddrawn($nextid)]} continue
	drawparentlinks $id $r

	set rowids [lindex $rowidlist $r]
	foreach lid $rowids {
	    if {$lid eq {}} continue
	    if {[info exists lineend($lid)] && $lineend($lid) > $r} continue
	    if {$lid eq $id} {
		# see if this is the first child of any of its parents
		foreach p [lindex $parentlist $r] {
		    if {[lsearch -exact $rowids $p] < 0} {
			# make this line extend up to the child
			set lineend($p) [drawlineseg $p $r $er 0]
		    }
		}
	    } else {
		set lineend($lid) [drawlineseg $lid $r $er 1]
	    }
	}
    }
}

proc undolayout {row} {
    global uparrowlen mingaplen downarrowlen
    global rowidlist rowisopt rowfinal need_redisplay

    set r [expr {$row - ($uparrowlen + $mingaplen + $downarrowlen)}]
    if {$r < 0} {
	set r 0
    }
    if {[llength $rowidlist] > $r} {
	incr r -1
	set rowidlist [lrange $rowidlist 0 $r]
	set rowfinal [lrange $rowfinal 0 $r]
	set rowisopt [lrange $rowisopt 0 $r]
	set need_redisplay 1
	run drawvisible
    }
}

proc drawvisible {} {
    global canv linespc curview vrowmod selectedline targetrow targetid
    global need_redisplay cscroll numcommits

    set fs [$canv yview]
    set ymax [lindex [$canv cget -scrollregion] 3]
    if {$ymax eq {} || $ymax == 0 || $numcommits == 0} return
    set f0 [lindex $fs 0]
    set f1 [lindex $fs 1]
    set y0 [expr {int($f0 * $ymax)}]
    set y1 [expr {int($f1 * $ymax)}]

    if {[info exists targetid]} {
	if {[commitinview $targetid $curview]} {
	    set r [rowofcommit $targetid]
	    if {$r != $targetrow} {
		# Fix up the scrollregion and change the scrolling position
		# now that our target row has moved.
		set diff [expr {($r - $targetrow) * $linespc}]
		set targetrow $r
		setcanvscroll
		set ymax [lindex [$canv cget -scrollregion] 3]
		incr y0 $diff
		incr y1 $diff
		set f0 [expr {$y0 / $ymax}]
		set f1 [expr {$y1 / $ymax}]
		allcanvs yview moveto $f0
		$cscroll set $f0 $f1
		set need_redisplay 1
	    }
	} else {
	    unset targetid
	}
    }

    set row [expr {int(($y0 - 3) / $linespc) - 1}]
    set endrow [expr {int(($y1 - 3) / $linespc) + 1}]
    if {$endrow >= $vrowmod($curview)} {
	update_arcrows $curview
    }
    if {$selectedline ne {} &&
	$row <= $selectedline && $selectedline <= $endrow} {
	set targetrow $selectedline
    } elseif {[info exists targetid]} {
	set targetrow [expr {int(($row + $endrow) / 2)}]
    }
    if {[info exists targetrow]} {
	if {$targetrow >= $numcommits} {
	    set targetrow [expr {$numcommits - 1}]
	}
	set targetid [commitonrow $targetrow]
    }
    drawcommits $row $endrow
}

proc clear_display {} {
    global iddrawn linesegs need_redisplay nrows_drawn
    global vhighlights fhighlights nhighlights rhighlights
    global linehtag linentag linedtag boldids boldnameids

    allcanvs delete all
    catch {unset iddrawn}
    catch {unset linesegs}
    catch {unset linehtag}
    catch {unset linentag}
    catch {unset linedtag}
    set boldids {}
    set boldnameids {}
    catch {unset vhighlights}
    catch {unset fhighlights}
    catch {unset nhighlights}
    catch {unset rhighlights}
    set need_redisplay 0
    set nrows_drawn 0
}

proc findcrossings {id} {
    global rowidlist parentlist numcommits displayorder

    set cross {}
    set ccross {}
    foreach {s e} [rowranges $id] {
	if {$e >= $numcommits} {
	    set e [expr {$numcommits - 1}]
	}
	if {$e <= $s} continue
	for {set row $e} {[incr row -1] >= $s} {} {
	    set x [lsearch -exact [lindex $rowidlist $row] $id]
	    if {$x < 0} break
	    set olds [lindex $parentlist $row]
	    set kid [lindex $displayorder $row]
	    set kidx [lsearch -exact [lindex $rowidlist $row] $kid]
	    if {$kidx < 0} continue
	    set nextrow [lindex $rowidlist [expr {$row + 1}]]
	    foreach p $olds {
		set px [lsearch -exact $nextrow $p]
		if {$px < 0} continue
		if {($kidx < $x && $x < $px) || ($px < $x && $x < $kidx)} {
		    if {[lsearch -exact $ccross $p] >= 0} continue
		    if {$x == $px + ($kidx < $px? -1: 1)} {
			lappend ccross $p
		    } elseif {[lsearch -exact $cross $p] < 0} {
			lappend cross $p
		    }
		}
	    }
	}
    }
    return [concat $ccross {{}} $cross]
}

proc assigncolor {id} {
    global colormap colors nextcolor
    global parents children children curview

    if {[info exists colormap($id)]} return
    set ncolors [llength $colors]
    if {[info exists children($curview,$id)]} {
	set kids $children($curview,$id)
    } else {
	set kids {}
    }
    if {[llength $kids] == 1} {
	set child [lindex $kids 0]
	if {[info exists colormap($child)]
	    && [llength $parents($curview,$child)] == 1} {
	    set colormap($id) $colormap($child)
	    return
	}
    }
    set badcolors {}
    set origbad {}
    foreach x [findcrossings $id] {
	if {$x eq {}} {
	    # delimiter between corner crossings and other crossings
	    if {[llength $badcolors] >= $ncolors - 1} break
	    set origbad $badcolors
	}
	if {[info exists colormap($x)]
	    && [lsearch -exact $badcolors $colormap($x)] < 0} {
	    lappend badcolors $colormap($x)
	}
    }
    if {[llength $badcolors] >= $ncolors} {
	set badcolors $origbad
    }
    set origbad $badcolors
    if {[llength $badcolors] < $ncolors - 1} {
	foreach child $kids {
	    if {[info exists colormap($child)]
		&& [lsearch -exact $badcolors $colormap($child)] < 0} {
		lappend badcolors $colormap($child)
	    }
	    foreach p $parents($curview,$child) {
		if {[info exists colormap($p)]
		    && [lsearch -exact $badcolors $colormap($p)] < 0} {
		    lappend badcolors $colormap($p)
		}
	    }
	}
	if {[llength $badcolors] >= $ncolors} {
	    set badcolors $origbad
	}
    }
    for {set i 0} {$i <= $ncolors} {incr i} {
	set c [lindex $colors $nextcolor]
	if {[incr nextcolor] >= $ncolors} {
	    set nextcolor 0
	}
	if {[lsearch -exact $badcolors $c]} break
    }
    set colormap($id) $c
}

proc bindline {t id} {
    global canv

    $canv bind $t <Enter> "lineenter %x %y $id"
    $canv bind $t <Motion> "linemotion %x %y $id"
    $canv bind $t <Leave> "lineleave $id"
    $canv bind $t <Button-1> "lineclick %x %y $id 1"
}

proc graph_pane_width {} {
    global use_ttk

    if {$use_ttk} {
	set g [.tf.histframe.pwclist sashpos 0]
    } else {
	set g [.tf.histframe.pwclist sash coord 0]
    }
    return [lindex $g 0]
}

proc totalwidth {l font extra} {
    set tot 0
    foreach str $l {
	set tot [expr {$tot + [font measure $font $str] + $extra}]
    }
    return $tot
}

proc drawtags {id x xt y1} {
    global idtags idheads idotherrefs mainhead
    global linespc lthickness
    global canv rowtextx curview fgcolor bgcolor ctxbut
    global headbgcolor headfgcolor headoutlinecolor remotebgcolor
    global tagbgcolor tagfgcolor tagoutlinecolor
    global reflinecolor

    set marks {}
    set ntags 0
    set nheads 0
    set singletag 0
    set maxtags 3
    set maxtagpct 25
    set maxwidth [expr {[graph_pane_width] * $maxtagpct / 100}]
    set delta [expr {int(0.5 * ($linespc - $lthickness))}]
    set extra [expr {$delta + $lthickness + $linespc}]

    if {[info exists idtags($id)]} {
	set marks $idtags($id)
	set ntags [llength $marks]
	if {$ntags > $maxtags ||
	    [totalwidth $marks mainfont $extra] > $maxwidth} {
	    # show just a single "n tags..." tag
	    set singletag 1
	    if {$ntags == 1} {
		set marks [list "tag..."]
	    } else {
		set marks [list [format "%d tags..." $ntags]]
	    }
	    set ntags 1
	}
    }
    if {[info exists idheads($id)]} {
	set marks [concat $marks $idheads($id)]
	set nheads [llength $idheads($id)]
    }
    if {[info exists idotherrefs($id)]} {
	set marks [concat $marks $idotherrefs($id)]
    }
    if {$marks eq {}} {
	return $xt
    }

    set yt [expr {$y1 - 0.5 * $linespc}]
    set yb [expr {$yt + $linespc - 1}]
    set xvals {}
    set wvals {}
    set i -1
    foreach tag $marks {
	incr i
	if {$i >= $ntags && $i < $ntags + $nheads && $tag eq $mainhead} {
	    set wid [font measure mainfontbold $tag]
	} else {
	    set wid [font measure mainfont $tag]
	}
	lappend xvals $xt
	lappend wvals $wid
	set xt [expr {$xt + $wid + $extra}]
    }
    set t [$canv create line $x $y1 [lindex $xvals end] $y1 \
	       -width $lthickness -fill $reflinecolor -tags tag.$id]
    $canv lower $t
    foreach tag $marks x $xvals wid $wvals {
	set tag_quoted [string map {% %%} $tag]
	set xl [expr {$x + $delta}]
	set xr [expr {$x + $delta + $wid + $lthickness}]
	set font mainfont
	if {[incr ntags -1] >= 0} {
	    # draw a tag
	    set t [$canv create polygon $x [expr {$yt + $delta}] $xl $yt \
		       $xr $yt $xr $yb $xl $yb $x [expr {$yb - $delta}] \
		       -width 1 -outline $tagoutlinecolor -fill $tagbgcolor \
		       -tags tag.$id]
	    if {$singletag} {
		set tagclick [list showtags $id 1]
	    } else {
		set tagclick [list showtag $tag_quoted 1]
	    }
	    $canv bind $t <1> $tagclick
	    set rowtextx([rowofcommit $id]) [expr {$xr + $linespc}]
	} else {
	    # draw a head or other ref
	    if {[incr nheads -1] >= 0} {
		set col $headbgcolor
		if {$tag eq $mainhead} {
		    set font mainfontbold
		}
	    } else {
		set col "#ddddff"
	    }
	    set xl [expr {$xl - $delta/2}]
	    $canv create polygon $x $yt $xr $yt $xr $yb $x $yb \
		-width 1 -outline black -fill $col -tags tag.$id
	    if {[regexp {^(remotes/.*/|remotes/)} $tag match remoteprefix]} {
	        set rwid [font measure mainfont $remoteprefix]
		set xi [expr {$x + 1}]
		set yti [expr {$yt + 1}]
		set xri [expr {$x + $rwid}]
		$canv create polygon $xi $yti $xri $yti $xri $yb $xi $yb \
			-width 0 -fill $remotebgcolor -tags tag.$id
	    }
	}
	set t [$canv create text $xl $y1 -anchor w -text $tag -fill $headfgcolor \
		   -font $font -tags [list tag.$id text]]
	if {$ntags >= 0} {
	    $canv bind $t <1> $tagclick
	} elseif {$nheads >= 0} {
	    $canv bind $t $ctxbut [list headmenu %X %Y $id $tag_quoted]
	}
    }
    return $xt
}

proc drawnotesign {xt y} {
    global linespc canv fgcolor

    set orad [expr {$linespc / 3}]
    set t [$canv create rectangle [expr {$xt - $orad}] [expr {$y - $orad}] \
	       [expr {$xt + $orad - 1}] [expr {$y + $orad - 1}] \
	       -fill yellow -outline $fgcolor -width 1 -tags circle]
    set xt [expr {$xt + $orad * 3}]
    return $xt
}

proc xcoord {i level ln} {
    global canvx0 xspc1 xspc2

    set x [expr {$canvx0 + $i * $xspc1($ln)}]
    if {$i > 0 && $i == $level} {
	set x [expr {$x + 0.5 * ($xspc2 - $xspc1($ln))}]
    } elseif {$i > $level} {
	set x [expr {$x + $xspc2 - $xspc1($ln)}]
    }
    return $x
}

proc show_status {msg} {
    global canv fgcolor

    clear_display
    $canv create text 3 3 -anchor nw -text $msg -font mainfont \
	-tags text -fill $fgcolor
}

# Don't change the text pane cursor if it is currently the hand cursor,
# showing that we are over a sha1 ID link.
proc settextcursor {c} {
    global ctext curtextcursor

    if {[$ctext cget -cursor] == $curtextcursor} {
	$ctext config -cursor $c
    }
    set curtextcursor $c
}

proc nowbusy {what {name {}}} {
    global isbusy busyname statusw

    if {[array names isbusy] eq {}} {
	. config -cursor watch
	settextcursor watch
    }
    set isbusy($what) 1
    set busyname($what) $name
    if {$name ne {}} {
	$statusw conf -text $name
    }
}

proc notbusy {what} {
    global isbusy maincursor textcursor busyname statusw

    catch {
	unset isbusy($what)
	if {$busyname($what) ne {} &&
	    [$statusw cget -text] eq $busyname($what)} {
	    $statusw conf -text {}
	}
    }
    if {[array names isbusy] eq {}} {
	. config -cursor $maincursor
	settextcursor $textcursor
    }
}

proc findmatches {f} {
    global findtype findstring
    if {$findtype == [mc "Regexp"]} {
	set matches [regexp -indices -all -inline $findstring $f]
    } else {
	set fs $findstring
	if {$findtype == [mc "IgnCase"]} {
	    set f [string tolower $f]
	    set fs [string tolower $fs]
	}
	set matches {}
	set i 0
	set l [string length $fs]
	while {[set j [string first $fs $f $i]] >= 0} {
	    lappend matches [list $j [expr {$j+$l-1}]]
	    set i [expr {$j + $l}]
	}
    }
    return $matches
}

proc dofind {{dirn 1} {wrap 1}} {
    global findstring findstartline findcurline selectedline numcommits
    global gdttype filehighlight fh_serial find_dirn findallowwrap

    if {[info exists find_dirn]} {
	if {$find_dirn == $dirn} return
	stopfinding
    }
    focus .
    if {$findstring eq {} || $numcommits == 0} return
    if {$selectedline eq {}} {
	set findstartline [lindex [visiblerows] [expr {$dirn < 0}]]
    } else {
	set findstartline $selectedline
    }
    set findcurline $findstartline
    nowbusy finding [mc "Searching"]
    if {$gdttype ne [mc "containing:"] && ![info exists filehighlight]} {
	after cancel do_file_hl $fh_serial
	do_file_hl $fh_serial
    }
    set find_dirn $dirn
    set findallowwrap $wrap
    run findmore
}

proc stopfinding {} {
    global find_dirn findcurline fprogcoord

    if {[info exists find_dirn]} {
	unset find_dirn
	unset findcurline
	notbusy finding
	set fprogcoord 0
	adjustprogress
    }
    stopblaming
}

proc findmore {} {
    global commitdata commitinfo numcommits findpattern findloc
    global findstartline findcurline findallowwrap
    global find_dirn gdttype fhighlights fprogcoord
    global curview varcorder vrownum varccommits vrowmod

    if {![info exists find_dirn]} {
	return 0
    }
    set fldtypes [list [mc "Headline"] [mc "Author"] "" [mc "Committer"] "" [mc "Comments"]]
    set l $findcurline
    set moretodo 0
    if {$find_dirn > 0} {
	incr l
	if {$l >= $numcommits} {
	    set l 0
	}
	if {$l <= $findstartline} {
	    set lim [expr {$findstartline + 1}]
	} else {
	    set lim $numcommits
	    set moretodo $findallowwrap
	}
    } else {
	if {$l == 0} {
	    set l $numcommits
	}
	incr l -1
	if {$l >= $findstartline} {
	    set lim [expr {$findstartline - 1}]
	} else {
	    set lim -1
	    set moretodo $findallowwrap
	}
    }
    set n [expr {($lim - $l) * $find_dirn}]
    if {$n > 500} {
	set n 500
	set moretodo 1
    }
    if {$l + ($find_dirn > 0? $n: 1) > $vrowmod($curview)} {
	update_arcrows $curview
    }
    set found 0
    set domore 1
    set ai [bsearch $vrownum($curview) $l]
    set a [lindex $varcorder($curview) $ai]
    set arow [lindex $vrownum($curview) $ai]
    set ids [lindex $varccommits($curview,$a)]
    set arowend [expr {$arow + [llength $ids]}]
    if {$gdttype eq [mc "containing:"]} {
	for {} {$n > 0} {incr n -1; incr l $find_dirn} {
	    if {$l < $arow || $l >= $arowend} {
		incr ai $find_dirn
		set a [lindex $varcorder($curview) $ai]
		set arow [lindex $vrownum($curview) $ai]
		set ids [lindex $varccommits($curview,$a)]
		set arowend [expr {$arow + [llength $ids]}]
	    }
	    set id [lindex $ids [expr {$l - $arow}]]
	    # shouldn't happen unless git log doesn't give all the commits...
	    if {![info exists commitdata($id)] ||
		![doesmatch $commitdata($id)]} {
		continue
	    }
	    if {![info exists commitinfo($id)]} {
		getcommit $id
	    }
	    set info $commitinfo($id)
	    foreach f $info ty $fldtypes {
		if {$ty eq ""} continue
		if {($findloc eq [mc "All fields"] || $findloc eq $ty) &&
		    [doesmatch $f]} {
		    set found 1
		    break
		}
	    }
	    if {$found} break
	}
    } else {
	for {} {$n > 0} {incr n -1; incr l $find_dirn} {
	    if {$l < $arow || $l >= $arowend} {
		incr ai $find_dirn
		set a [lindex $varcorder($curview) $ai]
		set arow [lindex $vrownum($curview) $ai]
		set ids [lindex $varccommits($curview,$a)]
		set arowend [expr {$arow + [llength $ids]}]
	    }
	    set id [lindex $ids [expr {$l - $arow}]]
	    if {![info exists fhighlights($id)]} {
		# this sets fhighlights($id) to -1
		askfilehighlight $l $id
	    }
	    if {$fhighlights($id) > 0} {
		set found $domore
		break
	    }
	    if {$fhighlights($id) < 0} {
		if {$domore} {
		    set domore 0
		    set findcurline [expr {$l - $find_dirn}]
		}
	    }
	}
    }
    if {$found || ($domore && !$moretodo)} {
	unset findcurline
	unset find_dirn
	notbusy finding
	set fprogcoord 0
	adjustprogress
	if {$found} {
	    findselectline $l
	} else {
	    bell
	}
	return 0
    }
    if {!$domore} {
	flushhighlights
    } else {
	set findcurline [expr {$l - $find_dirn}]
    }
    set n [expr {($findcurline - $findstartline) * $find_dirn - 1}]
    if {$n < 0} {
	incr n $numcommits
    }
    set fprogcoord [expr {$n * 1.0 / $numcommits}]
    adjustprogress
    return $domore
}

proc findselectline {l} {
    global findloc commentend ctext findcurline markingmatches gdttype

    set markingmatches [expr {$gdttype eq [mc "containing:"]}]
    set findcurline $l
    selectline $l 1
    if {$markingmatches &&
	($findloc eq [mc "All fields"] || $findloc eq [mc "Comments"])} {
	# highlight the matches in the comments
	set f [$ctext get 1.0 $commentend]
	set matches [findmatches $f]
	foreach match $matches {
	    set start [lindex $match 0]
	    set end [expr {[lindex $match 1] + 1}]
	    $ctext tag add found "1.0 + $start c" "1.0 + $end c"
	}
    }
    drawvisible
}

# mark the bits of a headline or author that match a find string
proc markmatches {canv l str tag matches font row} {
    global selectedline

    set bbox [$canv bbox $tag]
    set x0 [lindex $bbox 0]
    set y0 [lindex $bbox 1]
    set y1 [lindex $bbox 3]
    foreach match $matches {
	set start [lindex $match 0]
	set end [lindex $match 1]
	if {$start > $end} continue
	set xoff [font measure $font [string range $str 0 [expr {$start-1}]]]
	set xlen [font measure $font [string range $str 0 [expr {$end}]]]
	set t [$canv create rect [expr {$x0+$xoff}] $y0 \
		   [expr {$x0+$xlen+2}] $y1 \
		   -outline {} -tags [list match$l matches] -fill yellow]
	$canv lower $t
	if {$row == $selectedline} {
	    $canv raise $t secsel
	}
    }
}

proc unmarkmatches {} {
    global markingmatches

    allcanvs delete matches
    set markingmatches 0
    stopfinding
}

proc selcanvline {w x y} {
    global canv canvy0 ctext linespc
    global rowtextx
    set ymax [lindex [$canv cget -scrollregion] 3]
    if {$ymax == {}} return
    set yfrac [lindex [$canv yview] 0]
    set y [expr {$y + $yfrac * $ymax}]
    set l [expr {int(($y - $canvy0) / $linespc + 0.5)}]
    if {$l < 0} {
	set l 0
    }
    if {$w eq $canv} {
	set xmax [lindex [$canv cget -scrollregion] 2]
	set xleft [expr {[lindex [$canv xview] 0] * $xmax}]
	if {![info exists rowtextx($l)] || $xleft + $x < $rowtextx($l)} return
    }
    unmarkmatches
    selectline $l 1
}

proc commit_descriptor {p} {
    global commitinfo
    if {![info exists commitinfo($p)]} {
	getcommit $p
    }
    set l "..."
    if {[llength $commitinfo($p)] > 1} {
	set l [lindex $commitinfo($p) 0]
    }
    return "$p ($l)\n"
}

# append some text to the ctext widget, and make any SHA1 ID
# that we know about be a clickable link.
proc appendwithlinks {text tags} {
    global ctext linknum curview

    set start [$ctext index "end - 1c"]
    $ctext insert end $text $tags
    set links [regexp -indices -all -inline {(?:\m|-g)[0-9a-f]{6,40}\M} $text]
    foreach l $links {
	set s [lindex $l 0]
	set e [lindex $l 1]
	set linkid [string range $text $s $e]
	incr e
	$ctext tag delete link$linknum
	$ctext tag add link$linknum "$start + $s c" "$start + $e c"
	setlink $linkid link$linknum
	incr linknum
    }
}

proc setlink {id lk} {
    global curview ctext pendinglinks
    global linkfgcolor

    if {[string range $id 0 1] eq "-g"} {
      set id [string range $id 2 end]
    }

    set known 0
    if {[string length $id] < 40} {
	set matches [longid $id]
	if {[llength $matches] > 0} {
	    if {[llength $matches] > 1} return
	    set known 1
	    set id [lindex $matches 0]
	}
    } else {
	set known [commitinview $id $curview]
    }
    if {$known} {
	$ctext tag conf $lk -foreground $linkfgcolor -underline 1
	$ctext tag bind $lk <1> [list selbyid $id]
	$ctext tag bind $lk <Enter> {linkcursor %W 1}
	$ctext tag bind $lk <Leave> {linkcursor %W -1}
    } else {
	lappend pendinglinks($id) $lk
	interestedin $id {makelink %P}
    }
}

proc appendshortlink {id {pre {}} {post {}}} {
    global ctext linknum

    $ctext insert end $pre
    $ctext tag delete link$linknum
    $ctext insert end [string range $id 0 7] link$linknum
    $ctext insert end $post
    setlink $id link$linknum
    incr linknum
}

proc makelink {id} {
    global pendinglinks

    if {![info exists pendinglinks($id)]} return
    foreach lk $pendinglinks($id) {
	setlink $id $lk
    }
    unset pendinglinks($id)
}

proc linkcursor {w inc} {
    global linkentercount curtextcursor

    if {[incr linkentercount $inc] > 0} {
	$w configure -cursor hand2
    } else {
	$w configure -cursor $curtextcursor
	if {$linkentercount < 0} {
	    set linkentercount 0
	}
    }
}

proc viewnextline {dir} {
    global canv linespc

    $canv delete hover
    set ymax [lindex [$canv cget -scrollregion] 3]
    set wnow [$canv yview]
    set wtop [expr {[lindex $wnow 0] * $ymax}]
    set newtop [expr {$wtop + $dir * $linespc}]
    if {$newtop < 0} {
	set newtop 0
    } elseif {$newtop > $ymax} {
	set newtop $ymax
    }
    allcanvs yview moveto [expr {$newtop * 1.0 / $ymax}]
}

# add a list of tag or branch names at position pos
# returns the number of names inserted
proc appendrefs {pos ids var} {
    global ctext linknum curview $var maxrefs visiblerefs mainheadid

    if {[catch {$ctext index $pos}]} {
	return 0
    }
    $ctext conf -state normal
    $ctext delete $pos "$pos lineend"
    set tags {}
    foreach id $ids {
	foreach tag [set $var\($id\)] {
	    lappend tags [list $tag $id]
	}
    }

    set sep {}
    set tags [lsort -index 0 -decreasing $tags]
    set nutags 0

    if {[llength $tags] > $maxrefs} {
	# If we are displaying heads, and there are too many,
	# see if there are some important heads to display.
	# Currently that are the current head and heads listed in $visiblerefs option
	set itags {}
	if {$var eq "idheads"} {
	    set utags {}
	    foreach ti $tags {
		set hname [lindex $ti 0]
		set id [lindex $ti 1]
		if {([lsearch -exact $visiblerefs $hname] != -1 || $id eq $mainheadid) &&
		    [llength $itags] < $maxrefs} {
		    lappend itags $ti
		} else {
		    lappend utags $ti
		}
	    }
	    set tags $utags
	}
	if {$itags ne {}} {
	    set str [mc "and many more"]
	    set sep " "
	} else {
	    set str [mc "many"]
	}
	$ctext insert $pos "$str ([llength $tags])"
	set nutags [llength $tags]
	set tags $itags
    }

    foreach ti $tags {
	set id [lindex $ti 1]
	set lk link$linknum
	incr linknum
	$ctext tag delete $lk
	$ctext insert $pos $sep
	$ctext insert $pos [lindex $ti 0] $lk
	setlink $id $lk
	set sep ", "
    }
    $ctext tag add wwrap "$pos linestart" "$pos lineend"
    $ctext conf -state disabled
    return [expr {[llength $tags] + $nutags}]
}

# called when we have finished computing the nearby tags
proc dispneartags {delay} {
    global selectedline currentid showneartags tagphase

    if {$selectedline eq {} || !$showneartags} return
    after cancel dispnexttag
    if {$delay} {
	after 200 dispnexttag
	set tagphase -1
    } else {
	after idle dispnexttag
	set tagphase 0
    }
}

proc dispnexttag {} {
    global selectedline currentid showneartags tagphase ctext

    if {$selectedline eq {} || !$showneartags} return
    switch -- $tagphase {
	0 {
	    set dtags [desctags $currentid]
	    if {$dtags ne {}} {
		appendrefs precedes $dtags idtags
	    }
	}
	1 {
	    set atags [anctags $currentid]
	    if {$atags ne {}} {
		appendrefs follows $atags idtags
	    }
	}
	2 {
	    set dheads [descheads $currentid]
	    if {$dheads ne {}} {
		if {[appendrefs branch $dheads idheads] > 1
		    && [$ctext get "branch -3c"] eq "h"} {
		    # turn "Branch" into "Branches"
		    $ctext conf -state normal
		    $ctext insert "branch -2c" "es"
		    $ctext conf -state disabled
		}
	    }
	}
    }
    if {[incr tagphase] <= 2} {
	after idle dispnexttag
    }
}

proc make_secsel {id} {
    global linehtag linentag linedtag canv canv2 canv3

    if {![info exists linehtag($id)]} return
    $canv delete secsel
    set t [eval $canv create rect [$canv bbox $linehtag($id)] -outline {{}} \
	       -tags secsel -fill [$canv cget -selectbackground]]
    $canv lower $t
    $canv2 delete secsel
    set t [eval $canv2 create rect [$canv2 bbox $linentag($id)] -outline {{}} \
	       -tags secsel -fill [$canv2 cget -selectbackground]]
    $canv2 lower $t
    $canv3 delete secsel
    set t [eval $canv3 create rect [$canv3 bbox $linedtag($id)] -outline {{}} \
	       -tags secsel -fill [$canv3 cget -selectbackground]]
    $canv3 lower $t
}

proc make_idmark {id} {
    global linehtag canv fgcolor

    if {![info exists linehtag($id)]} return
    $canv delete markid
    set t [eval $canv create rect [$canv bbox $linehtag($id)] \
	       -tags markid -outline $fgcolor]
    $canv raise $t
}

proc selectline {l isnew {desired_loc {}} {switch_to_patch 0}} {
    global canv ctext commitinfo selectedline
    global canvy0 linespc parents children curview
    global currentid sha1entry
    global commentend idtags linknum
    global mergemax numcommits pending_select
    global cmitmode showneartags allcommits
    global targetrow targetid lastscrollrows
    global autoselect autosellen jump_to_here
    global vinlinediff

    catch {unset pending_select}
    $canv delete hover
    normalline
    unsel_reflist
    stopfinding
    if {$l < 0 || $l >= $numcommits} return
    set id [commitonrow $l]
    set targetid $id
    set targetrow $l
    set selectedline $l
    set currentid $id
    if {$lastscrollrows < $numcommits} {
	setcanvscroll
    }

    if {$cmitmode ne "patch" && $switch_to_patch} {
        set cmitmode "patch"
    }

    set y [expr {$canvy0 + $l * $linespc}]
    set ymax [lindex [$canv cget -scrollregion] 3]
    set ytop [expr {$y - $linespc - 1}]
    set ybot [expr {$y + $linespc + 1}]
    set wnow [$canv yview]
    set wtop [expr {[lindex $wnow 0] * $ymax}]
    set wbot [expr {[lindex $wnow 1] * $ymax}]
    set wh [expr {$wbot - $wtop}]
    set newtop $wtop
    if {$ytop < $wtop} {
	if {$ybot < $wtop} {
	    set newtop [expr {$y - $wh / 2.0}]
	} else {
	    set newtop $ytop
	    if {$newtop > $wtop - $linespc} {
		set newtop [expr {$wtop - $linespc}]
	    }
	}
    } elseif {$ybot > $wbot} {
	if {$ytop > $wbot} {
	    set newtop [expr {$y - $wh / 2.0}]
	} else {
	    set newtop [expr {$ybot - $wh}]
	    if {$newtop < $wtop + $linespc} {
		set newtop [expr {$wtop + $linespc}]
	    }
	}
    }
    if {$newtop != $wtop} {
	if {$newtop < 0} {
	    set newtop 0
	}
	allcanvs yview moveto [expr {$newtop * 1.0 / $ymax}]
	drawvisible
    }

    make_secsel $id

    if {$isnew} {
	addtohistory [list selbyid $id 0] savecmitpos
    }

    $sha1entry delete 0 end
    $sha1entry insert 0 $id
    if {$autoselect} {
	$sha1entry selection range 0 $autosellen
    }
    rhighlight_sel $id

    $ctext conf -state normal
    clear_ctext
    set linknum 0
    if {![info exists commitinfo($id)]} {
	getcommit $id
    }
    set info $commitinfo($id)
    set date [formatdate [lindex $info 2]]
    $ctext insert end "[mc "Author"]: [lindex $info 1]  $date\n"
    set date [formatdate [lindex $info 4]]
    $ctext insert end "[mc "Committer"]: [lindex $info 3]  $date\n"
    if {[info exists idtags($id)]} {
	$ctext insert end [mc "Tags:"]
	foreach tag $idtags($id) {
	    $ctext insert end " $tag"
	}
	$ctext insert end "\n"
    }

    set headers {}
    set olds $parents($curview,$id)
    if {[llength $olds] > 1} {
	set np 0
	foreach p $olds {
	    if {$np >= $mergemax} {
		set tag mmax
	    } else {
		set tag m$np
	    }
	    $ctext insert end "[mc "Parent"]: " $tag
	    appendwithlinks [commit_descriptor $p] {}
	    incr np
	}
    } else {
	foreach p $olds {
	    append headers "[mc "Parent"]: [commit_descriptor $p]"
	}
    }

    foreach c $children($curview,$id) {
	append headers "[mc "Child"]:  [commit_descriptor $c]"
    }

    # make anything that looks like a SHA1 ID be a clickable link
    appendwithlinks $headers {}
    if {$showneartags} {
	if {![info exists allcommits]} {
	    getallcommits
	}
	$ctext insert end "[mc "Branch"]: "
	$ctext mark set branch "end -1c"
	$ctext mark gravity branch left
	$ctext insert end "\n[mc "Follows"]: "
	$ctext mark set follows "end -1c"
	$ctext mark gravity follows left
	$ctext insert end "\n[mc "Precedes"]: "
	$ctext mark set precedes "end -1c"
	$ctext mark gravity precedes left
	$ctext insert end "\n"
	dispneartags 1
    }
    $ctext insert end "\n"
    set comment [lindex $info 5]
    if {[string first "\r" $comment] >= 0} {
	set comment [string map {"\r" "\n    "} $comment]
    }
    appendwithlinks $comment {comment}

    $ctext tag remove found 1.0 end
    $ctext conf -state disabled
    set commentend [$ctext index "end - 1c"]

    set jump_to_here $desired_loc
    init_flist [mc "Comments"]
    if {$cmitmode eq "tree"} {
	gettree $id
    } elseif {$vinlinediff($curview) == 1} {
	showinlinediff $id
    } elseif {[llength $olds] <= 1} {
	startdiff $id
    } else {
	mergediff $id
    }
}

proc selfirstline {} {
    unmarkmatches
    selectline 0 1
}

proc sellastline {} {
    global numcommits
    unmarkmatches
    set l [expr {$numcommits - 1}]
    selectline $l 1
}

proc selnextline {dir} {
    global selectedline
    focus .
    if {$selectedline eq {}} return
    set l [expr {$selectedline + $dir}]
    unmarkmatches
    selectline $l 1
}

proc selnextpage {dir} {
    global canv linespc selectedline numcommits

    set lpp [expr {([winfo height $canv] - 2) / $linespc}]
    if {$lpp < 1} {
	set lpp 1
    }
    allcanvs yview scroll [expr {$dir * $lpp}] units
    drawvisible
    if {$selectedline eq {}} return
    set l [expr {$selectedline + $dir * $lpp}]
    if {$l < 0} {
	set l 0
    } elseif {$l >= $numcommits} {
        set l [expr $numcommits - 1]
    }
    unmarkmatches
    selectline $l 1
}

proc unselectline {} {
    global selectedline currentid

    set selectedline {}
    catch {unset currentid}
    allcanvs delete secsel
    rhighlight_none
}

proc reselectline {} {
    global selectedline

    if {$selectedline ne {}} {
	selectline $selectedline 0
    }
}

proc addtohistory {cmd {saveproc {}}} {
    global history historyindex curview

    unset_posvars
    save_position
    set elt [list $curview $cmd $saveproc {}]
    if {$historyindex > 0
	&& [lindex $history [expr {$historyindex - 1}]] == $elt} {
	return
    }

    if {$historyindex < [llength $history]} {
	set history [lreplace $history $historyindex end $elt]
    } else {
	lappend history $elt
    }
    incr historyindex
    if {$historyindex > 1} {
	.tf.bar.leftbut conf -state normal
    } else {
	.tf.bar.leftbut conf -state disabled
    }
    .tf.bar.rightbut conf -state disabled
}

# save the scrolling position of the diff display pane
proc save_position {} {
    global historyindex history

    if {$historyindex < 1} return
    set hi [expr {$historyindex - 1}]
    set fn [lindex $history $hi 2]
    if {$fn ne {}} {
	lset history $hi 3 [eval $fn]
    }
}

proc unset_posvars {} {
    global last_posvars

    if {[info exists last_posvars]} {
	foreach {var val} $last_posvars {
	    global $var
	    catch {unset $var}
	}
	unset last_posvars
    }
}

proc godo {elt} {
    global curview last_posvars

    set view [lindex $elt 0]
    set cmd [lindex $elt 1]
    set pv [lindex $elt 3]
    if {$curview != $view} {
	showview $view
    }
    unset_posvars
    foreach {var val} $pv {
	global $var
	set $var $val
    }
    set last_posvars $pv
    eval $cmd
}

proc goback {} {
    global history historyindex
    focus .

    if {$historyindex > 1} {
	save_position
	incr historyindex -1
	godo [lindex $history [expr {$historyindex - 1}]]
	.tf.bar.rightbut conf -state normal
    }
    if {$historyindex <= 1} {
	.tf.bar.leftbut conf -state disabled
    }
}

proc goforw {} {
    global history historyindex
    focus .

    if {$historyindex < [llength $history]} {
	save_position
	set cmd [lindex $history $historyindex]
	incr historyindex
	godo $cmd
	.tf.bar.leftbut conf -state normal
    }
    if {$historyindex >= [llength $history]} {
	.tf.bar.rightbut conf -state disabled
    }
}

proc go_to_parent {i} {
    global parents curview targetid
    set ps $parents($curview,$targetid)
    if {[llength $ps] >= $i} {
	selbyid [lindex $ps [expr $i - 1]]
    }
}

proc gettree {id} {
    global treefilelist treeidlist diffids diffmergeid treepending
    global nullid nullid2

    set diffids $id
    catch {unset diffmergeid}
    if {![info exists treefilelist($id)]} {
	if {![info exists treepending]} {
	    if {$id eq $nullid} {
		set cmd [list | git ls-files]
	    } elseif {$id eq $nullid2} {
		set cmd [list | git ls-files --stage -t]
	    } else {
		set cmd [list | git ls-tree -r $id]
	    }
	    if {[catch {set gtf [open $cmd r]}]} {
		return
	    }
	    set treepending $id
	    set treefilelist($id) {}
	    set treeidlist($id) {}
	    fconfigure $gtf -blocking 0 -encoding binary
	    filerun $gtf [list gettreeline $gtf $id]
	}
    } else {
	setfilelist $id
    }
}

proc gettreeline {gtf id} {
    global treefilelist treeidlist treepending cmitmode diffids nullid nullid2

    set nl 0
    while {[incr nl] <= 1000 && [gets $gtf line] >= 0} {
	if {$diffids eq $nullid} {
	    set fname $line
	} else {
	    set i [string first "\t" $line]
	    if {$i < 0} continue
	    set fname [string range $line [expr {$i+1}] end]
	    set line [string range $line 0 [expr {$i-1}]]
	    if {$diffids ne $nullid2 && [lindex $line 1] ne "blob"} continue
	    set sha1 [lindex $line 2]
	    lappend treeidlist($id) $sha1
	}
	if {[string index $fname 0] eq "\""} {
	    set fname [lindex $fname 0]
	}
	set fname [encoding convertfrom $fname]
	lappend treefilelist($id) $fname
    }
    if {![eof $gtf]} {
	return [expr {$nl >= 1000? 2: 1}]
    }
    close $gtf
    unset treepending
    if {$cmitmode ne "tree"} {
	if {![info exists diffmergeid]} {
	    gettreediffs $diffids
	}
    } elseif {$id ne $diffids} {
	gettree $diffids
    } else {
	setfilelist $id
    }
    return 0
}

proc showfile {f} {
    global treefilelist treeidlist diffids nullid nullid2
    global ctext_file_names ctext_file_lines
    global ctext commentend

    set i [lsearch -exact $treefilelist($diffids) $f]
    if {$i < 0} {
	puts "oops, $f not in list for id $diffids"
	return
    }
    if {$diffids eq $nullid} {
	if {[catch {set bf [open $f r]} err]} {
	    puts "oops, can't read $f: $err"
	    return
	}
    } else {
	set blob [lindex $treeidlist($diffids) $i]
	if {[catch {set bf [open [concat | git cat-file blob $blob] r]} err]} {
	    puts "oops, error reading blob $blob: $err"
	    return
	}
    }
    fconfigure $bf -blocking 0 -encoding [get_path_encoding $f]
    filerun $bf [list getblobline $bf $diffids]
    $ctext config -state normal
    clear_ctext $commentend
    lappend ctext_file_names $f
    lappend ctext_file_lines [lindex [split $commentend "."] 0]
    $ctext insert end "\n"
    $ctext insert end "$f\n" filesep
    $ctext config -state disabled
    $ctext yview $commentend
    settabs 0
}

proc getblobline {bf id} {
    global diffids cmitmode ctext

    if {$id ne $diffids || $cmitmode ne "tree"} {
	catch {close $bf}
	return 0
    }
    $ctext config -state normal
    set nl 0
    while {[incr nl] <= 1000 && [gets $bf line] >= 0} {
	$ctext insert end "$line\n"
    }
    if {[eof $bf]} {
	global jump_to_here ctext_file_names commentend

	# delete last newline
	$ctext delete "end - 2c" "end - 1c"
	close $bf
	if {$jump_to_here ne {} &&
	    [lindex $jump_to_here 0] eq [lindex $ctext_file_names 0]} {
	    set lnum [expr {[lindex $jump_to_here 1] +
			    [lindex [split $commentend .] 0]}]
	    mark_ctext_line $lnum
	}
	$ctext config -state disabled
	return 0
    }
    $ctext config -state disabled
    return [expr {$nl >= 1000? 2: 1}]
}

proc mark_ctext_line {lnum} {
    global ctext markbgcolor

    $ctext tag delete omark
    $ctext tag add omark $lnum.0 "$lnum.0 + 1 line"
    $ctext tag conf omark -background $markbgcolor
    $ctext see $lnum.0
}

proc mergediff {id} {
    global diffmergeid
    global diffids treediffs
    global parents curview

    set diffmergeid $id
    set diffids $id
    set treediffs($id) {}
    set np [llength $parents($curview,$id)]
    settabs $np
    getblobdiffs $id
}

proc startdiff {ids} {
    global treediffs diffids treepending diffmergeid nullid nullid2

    settabs 1
    set diffids $ids
    catch {unset diffmergeid}
    if {![info exists treediffs($ids)] ||
	[lsearch -exact $ids $nullid] >= 0 ||
	[lsearch -exact $ids $nullid2] >= 0} {
	if {![info exists treepending]} {
	    gettreediffs $ids
	}
    } else {
	addtocflist $ids
    }
}

proc showinlinediff {ids} {
    global commitinfo commitdata ctext
    global treediffs

    set info $commitinfo($ids)
    set diff [lindex $info 7]
    set difflines [split $diff "\n"]

    initblobdiffvars
    set treediff {}

    set inhdr 0
    foreach line $difflines {
	if {![string compare -length 5 "diff " $line]} {
	    set inhdr 1
	} elseif {$inhdr && ![string compare -length 4 "+++ " $line]} {
	    # offset also accounts for the b/ prefix
	    lappend treediff [string range $line 6 end]
	    set inhdr 0
	}
    }

    set treediffs($ids) $treediff
    add_flist $treediff

    $ctext conf -state normal
    foreach line $difflines {
	parseblobdiffline $ids $line
    }
    maybe_scroll_ctext 1
    $ctext conf -state disabled
}

# If the filename (name) is under any of the passed filter paths
# then return true to include the file in the listing.
proc path_filter {filter name} {
    set worktree [gitworktree]
    foreach p $filter {
	set fq_p [file normalize $p]
	set fq_n [file normalize [file join $worktree $name]]
	if {[string match [file normalize $fq_p]* $fq_n]} {
	    return 1
	}
    }
    return 0
}

proc addtocflist {ids} {
    global treediffs

    add_flist $treediffs($ids)
    getblobdiffs $ids
}

proc diffcmd {ids flags} {
    global log_showroot nullid nullid2 git_version

    set i [lsearch -exact $ids $nullid]
    set j [lsearch -exact $ids $nullid2]
    if {$i >= 0} {
	if {[llength $ids] > 1 && $j < 0} {
	    # comparing working directory with some specific revision
	    set cmd [concat | git diff-index $flags]
	    if {$i == 0} {
		lappend cmd -R [lindex $ids 1]
	    } else {
		lappend cmd [lindex $ids 0]
	    }
	} else {
	    # comparing working directory with index
	    set cmd [concat | git diff-files $flags]
	    if {$j == 1} {
		lappend cmd -R
	    }
	}
    } elseif {$j >= 0} {
	if {[package vcompare $git_version "1.7.2"] >= 0} {
	    set flags "$flags --ignore-submodules=dirty"
	}
	set cmd [concat | git diff-index --cached $flags]
	if {[llength $ids] > 1} {
	    # comparing index with specific revision
	    if {$j == 0} {
		lappend cmd -R [lindex $ids 1]
	    } else {
		lappend cmd [lindex $ids 0]
	    }
	} else {
	    # comparing index with HEAD
	    lappend cmd HEAD
	}
    } else {
	if {$log_showroot} {
	    lappend flags --root
	}
	set cmd [concat | git diff-tree -r $flags $ids]
    }
    return $cmd
}

proc gettreediffs {ids} {
    global treediff treepending limitdiffs vfilelimit curview

    set cmd [diffcmd $ids {--no-commit-id}]
    if {$limitdiffs && $vfilelimit($curview) ne {}} {
	    set cmd [concat $cmd -- $vfilelimit($curview)]
    }
    if {[catch {set gdtf [open $cmd r]}]} return

    set treepending $ids
    set treediff {}
    fconfigure $gdtf -blocking 0 -encoding binary
    filerun $gdtf [list gettreediffline $gdtf $ids]
}

proc gettreediffline {gdtf ids} {
    global treediff treediffs treepending diffids diffmergeid
    global cmitmode vfilelimit curview limitdiffs perfile_attrs

    set nr 0
    set sublist {}
    set max 1000
    if {$perfile_attrs} {
	# cache_gitattr is slow, and even slower on win32 where we
	# have to invoke it for only about 30 paths at a time
	set max 500
	if {[tk windowingsystem] == "win32"} {
	    set max 120
	}
    }
    while {[incr nr] <= $max && [gets $gdtf line] >= 0} {
	set i [string first "\t" $line]
	if {$i >= 0} {
	    set file [string range $line [expr {$i+1}] end]
	    if {[string index $file 0] eq "\""} {
		set file [lindex $file 0]
	    }
	    set file [encoding convertfrom $file]
	    if {$file ne [lindex $treediff end]} {
		lappend treediff $file
		lappend sublist $file
	    }
	}
    }
    if {$perfile_attrs} {
	cache_gitattr encoding $sublist
    }
    if {![eof $gdtf]} {
	return [expr {$nr >= $max? 2: 1}]
    }
    close $gdtf
    set treediffs($ids) $treediff
    unset treepending
    if {$cmitmode eq "tree" && [llength $diffids] == 1} {
	gettree $diffids
    } elseif {$ids != $diffids} {
	if {![info exists diffmergeid]} {
	    gettreediffs $diffids
	}
    } else {
	addtocflist $ids
    }
    return 0
}

# empty string or positive integer
proc diffcontextvalidate {v} {
    return [regexp {^(|[1-9][0-9]*)$} $v]
}

proc diffcontextchange {n1 n2 op} {
    global diffcontextstring diffcontext

    if {[string is integer -strict $diffcontextstring]} {
	if {$diffcontextstring >= 0} {
	    set diffcontext $diffcontextstring
	    reselectline
	}
    }
}

proc changeignorespace {} {
    reselectline
}

proc changeworddiff {name ix op} {
    reselectline
}

proc initblobdiffvars {} {
    global diffencoding targetline diffnparents
    global diffinhdr currdiffsubmod diffseehere
    set targetline {}
    set diffnparents 0
    set diffinhdr 0
    set diffencoding [get_path_encoding {}]
    set currdiffsubmod ""
    set diffseehere -1
}

proc getblobdiffs {ids} {
    global blobdifffd diffids env
    global treediffs
    global diffcontext
    global ignorespace
    global worddiff
    global limitdiffs vfilelimit curview
    global git_version

    set textconv {}
    if {[package vcompare $git_version "1.6.1"] >= 0} {
	set textconv "--textconv"
    }
    set submodule {}
    if {[package vcompare $git_version "1.6.6"] >= 0} {
	set submodule "--submodule"
    }
    set cmd [diffcmd $ids "-p $textconv $submodule  -C --cc --no-commit-id -U$diffcontext"]
    if {$ignorespace} {
	append cmd " -w"
    }
    if {$worddiff ne [mc "Line diff"]} {
	append cmd " --word-diff=porcelain"
    }
    if {$limitdiffs && $vfilelimit($curview) ne {}} {
	set cmd [concat $cmd -- $vfilelimit($curview)]
    }
    if {[catch {set bdf [open $cmd r]} err]} {
	error_popup [mc "Error getting diffs: %s" $err]
	return
    }
    fconfigure $bdf -blocking 0 -encoding binary -eofchar {}
    set blobdifffd($ids) $bdf
    initblobdiffvars
    filerun $bdf [list getblobdiffline $bdf $diffids]
}

proc savecmitpos {} {
    global ctext cmitmode

    if {$cmitmode eq "tree"} {
	return {}
    }
    return [list target_scrollpos [$ctext index @0,0]]
}

proc savectextpos {} {
    global ctext

    return [list target_scrollpos [$ctext index @0,0]]
}

proc maybe_scroll_ctext {ateof} {
    global ctext target_scrollpos

    if {![info exists target_scrollpos]} return
    if {!$ateof} {
	set nlines [expr {[winfo height $ctext]
			  / [font metrics textfont -linespace]}]
	if {[$ctext compare "$target_scrollpos + $nlines lines" <= end]} return
    }
    $ctext yview $target_scrollpos
    unset target_scrollpos
}

proc setinlist {var i val} {
    global $var

    while {[llength [set $var]] < $i} {
	lappend $var {}
    }
    if {[llength [set $var]] == $i} {
	lappend $var $val
    } else {
	lset $var $i $val
    }
}

proc makediffhdr {fname ids} {
    global ctext curdiffstart treediffs diffencoding
    global ctext_file_names jump_to_here targetline diffline

    set fname [encoding convertfrom $fname]
    set diffencoding [get_path_encoding $fname]
    set i [lsearch -exact $treediffs($ids) $fname]
    if {$i >= 0} {
	setinlist difffilestart $i $curdiffstart
    }
    lset ctext_file_names end $fname
    set l [expr {(78 - [string length $fname]) / 2}]
    set pad [string range "----------------------------------------" 1 $l]
    $ctext insert $curdiffstart "$pad $fname $pad" filesep
    set targetline {}
    if {$jump_to_here ne {} && [lindex $jump_to_here 0] eq $fname} {
	set targetline [lindex $jump_to_here 1]
    }
    set diffline 0
}

proc blobdiffmaybeseehere {ateof} {
    global diffseehere
    if {$diffseehere >= 0} {
	mark_ctext_line [lindex [split $diffseehere .] 0]
    }
    maybe_scroll_ctext $ateof
}

proc getblobdiffline {bdf ids} {
    global diffids blobdifffd
    global ctext

    set nr 0
    $ctext conf -state normal
    while {[incr nr] <= 1000 && [gets $bdf line] >= 0} {
	if {$ids != $diffids || $bdf != $blobdifffd($ids)} {
	    catch {close $bdf}
	    return 0
	}
	parseblobdiffline $ids $line
    }
    $ctext conf -state disabled
    blobdiffmaybeseehere [eof $bdf]
    if {[eof $bdf]} {
	catch {close $bdf}
	return 0
    }
    return [expr {$nr >= 1000? 2: 1}]
}

proc parseblobdiffline {ids line} {
    global ctext curdiffstart
    global diffnexthead diffnextnote difffilestart
    global ctext_file_names ctext_file_lines
    global diffinhdr treediffs mergemax diffnparents
    global diffencoding jump_to_here targetline diffline currdiffsubmod
    global worddiff diffseehere

    if {![string compare -length 5 "diff " $line]} {
	if {![regexp {^diff (--cc|--git) } $line m type]} {
	    set line [encoding convertfrom $line]
	    $ctext insert end "$line\n" hunksep
	    continue
	}
	# start of a new file
	set diffinhdr 1
	$ctext insert end "\n"
	set curdiffstart [$ctext index "end - 1c"]
	lappend ctext_file_names ""
	lappend ctext_file_lines [lindex [split $curdiffstart "."] 0]
	$ctext insert end "\n" filesep

	if {$type eq "--cc"} {
	    # start of a new file in a merge diff
	    set fname [string range $line 10 end]
	    if {[lsearch -exact $treediffs($ids) $fname] < 0} {
		lappend treediffs($ids) $fname
		add_flist [list $fname]
	    }

	} else {
	    set line [string range $line 11 end]
	    # If the name hasn't changed the length will be odd,
	    # the middle char will be a space, and the two bits either
	    # side will be a/name and b/name, or "a/name" and "b/name".
	    # If the name has changed we'll get "rename from" and
	    # "rename to" or "copy from" and "copy to" lines following
	    # this, and we'll use them to get the filenames.
	    # This complexity is necessary because spaces in the
	    # filename(s) don't get escaped.
	    set l [string length $line]
	    set i [expr {$l / 2}]
	    if {!(($l & 1) && [string index $line $i] eq " " &&
		  [string range $line 2 [expr {$i - 1}]] eq \
		      [string range $line [expr {$i + 3}] end])} {
		return
	    }
	    # unescape if quoted and chop off the a/ from the front
	    if {[string index $line 0] eq "\""} {
		set fname [string range [lindex $line 0] 2 end]
	    } else {
		set fname [string range $line 2 [expr {$i - 1}]]
	    }
	}
	makediffhdr $fname $ids

    } elseif {![string compare -length 16 "* Unmerged path " $line]} {
	set fname [encoding convertfrom [string range $line 16 end]]
	$ctext insert end "\n"
	set curdiffstart [$ctext index "end - 1c"]
	lappend ctext_file_names $fname
	lappend ctext_file_lines [lindex [split $curdiffstart "."] 0]
	$ctext insert end "$line\n" filesep
	set i [lsearch -exact $treediffs($ids) $fname]
	if {$i >= 0} {
	    setinlist difffilestart $i $curdiffstart
	}

    } elseif {![string compare -length 2 "@@" $line]} {
	regexp {^@@+} $line ats
	set line [encoding convertfrom $diffencoding $line]
	$ctext insert end "$line\n" hunksep
	if {[regexp { \+(\d+),\d+ @@} $line m nl]} {
	    set diffline $nl
	}
	set diffnparents [expr {[string length $ats] - 1}]
	set diffinhdr 0

    } elseif {![string compare -length 10 "Submodule " $line]} {
	# start of a new submodule
	if {[regexp -indices "\[0-9a-f\]+\\.\\." $line nameend]} {
	    set fname [string range $line 10 [expr [lindex $nameend 0] - 2]]
	} else {
	    set fname [string range $line 10 [expr [string first "contains " $line] - 2]]
	}
	if {$currdiffsubmod != $fname} {
	    $ctext insert end "\n";     # Add newline after commit message
	}
	set curdiffstart [$ctext index "end - 1c"]
	lappend ctext_file_names ""
	if {$currdiffsubmod != $fname} {
	    lappend ctext_file_lines $fname
	    makediffhdr $fname $ids
	    set currdiffsubmod $fname
	    $ctext insert end "\n$line\n" filesep
	} else {
	    $ctext insert end "$line\n" filesep
	}
    } elseif {![string compare -length 3 "  >" $line]} {
	set $currdiffsubmod ""
	set line [encoding convertfrom $diffencoding $line]
	$ctext insert end "$line\n" dresult
    } elseif {![string compare -length 3 "  <" $line]} {
	set $currdiffsubmod ""
	set line [encoding convertfrom $diffencoding $line]
	$ctext insert end "$line\n" d0
    } elseif {$diffinhdr} {
	if {![string compare -length 12 "rename from " $line]} {
	    set fname [string range $line [expr 6 + [string first " from " $line] ] end]
	    if {[string index $fname 0] eq "\""} {
		set fname [lindex $fname 0]
	    }
	    set fname [encoding convertfrom $fname]
	    set i [lsearch -exact $treediffs($ids) $fname]
	    if {$i >= 0} {
		setinlist difffilestart $i $curdiffstart
	    }
	} elseif {![string compare -length 10 $line "rename to "] ||
		  ![string compare -length 8 $line "copy to "]} {
	    set fname [string range $line [expr 4 + [string first " to " $line] ] end]
	    if {[string index $fname 0] eq "\""} {
		set fname [lindex $fname 0]
	    }
	    makediffhdr $fname $ids
	} elseif {[string compare -length 3 $line "---"] == 0} {
	    # do nothing
	    return
	} elseif {[string compare -length 3 $line "+++"] == 0} {
	    set diffinhdr 0
	    return
	}
	$ctext insert end "$line\n" filesep

    } else {
	set line [string map {\x1A ^Z} \
		      [encoding convertfrom $diffencoding $line]]
	# parse the prefix - one ' ', '-' or '+' for each parent
	set prefix [string range $line 0 [expr {$diffnparents - 1}]]
	set tag [expr {$diffnparents > 1? "m": "d"}]
	set dowords [expr {$worddiff ne [mc "Line diff"] && $diffnparents == 1}]
	set words_pre_markup ""
	set words_post_markup ""
	if {[string trim $prefix " -+"] eq {}} {
	    # prefix only has " ", "-" and "+" in it: normal diff line
	    set num [string first "-" $prefix]
	    if {$dowords} {
		set line [string range $line 1 end]
	    }
	    if {$num >= 0} {
		# removed line, first parent with line is $num
		if {$num >= $mergemax} {
		    set num "max"
		}
		if {$dowords && $worddiff eq [mc "Markup words"]} {
		    $ctext insert end "\[-$line-\]" $tag$num
		} else {
		    $ctext insert end "$line" $tag$num
		}
		if {!$dowords} {
		    $ctext insert end "\n" $tag$num
		}
	    } else {
		set tags {}
		if {[string first "+" $prefix] >= 0} {
		    # added line
		    lappend tags ${tag}result
		    if {$diffnparents > 1} {
			set num [string first " " $prefix]
			if {$num >= 0} {
			    if {$num >= $mergemax} {
				set num "max"
			    }
			    lappend tags m$num
			}
		    }
		    set words_pre_markup "{+"
		    set words_post_markup "+}"
		}
		if {$targetline ne {}} {
		    if {$diffline == $targetline} {
			set diffseehere [$ctext index "end - 1 chars"]
			set targetline {}
		    } else {
			incr diffline
		    }
		}
		if {$dowords && $worddiff eq [mc "Markup words"]} {
		    $ctext insert end "$words_pre_markup$line$words_post_markup" $tags
		} else {
		    $ctext insert end "$line" $tags
		}
		if {!$dowords} {
		    $ctext insert end "\n" $tags
		}
	    }
	} elseif {$dowords && $prefix eq "~"} {
	    $ctext insert end "\n" {}
	} else {
	    # "\ No newline at end of file",
	    # or something else we don't recognize
	    $ctext insert end "$line\n" hunksep
	}
    }
}

proc changediffdisp {} {
    global ctext diffelide

    $ctext tag conf d0 -elide [lindex $diffelide 0]
    $ctext tag conf dresult -elide [lindex $diffelide 1]
}

proc highlightfile {cline} {
    global cflist cflist_top

    if {![info exists cflist_top]} return

    $cflist tag remove highlight $cflist_top.0 "$cflist_top.0 lineend"
    $cflist tag add highlight $cline.0 "$cline.0 lineend"
    $cflist see $cline.0
    set cflist_top $cline
}

proc highlightfile_for_scrollpos {topidx} {
    global cmitmode difffilestart

    if {$cmitmode eq "tree"} return
    if {![info exists difffilestart]} return

    set top [lindex [split $topidx .] 0]
    if {$difffilestart eq {} || $top < [lindex $difffilestart 0]} {
	highlightfile 0
    } else {
	highlightfile [expr {[bsearch $difffilestart $top] + 2}]
    }
}

proc prevfile {} {
    global difffilestart ctext cmitmode

    if {$cmitmode eq "tree"} return
    set prev 0.0
    set here [$ctext index @0,0]
    foreach loc $difffilestart {
	if {[$ctext compare $loc >= $here]} {
	    $ctext yview $prev
	    return
	}
	set prev $loc
    }
    $ctext yview $prev
}

proc nextfile {} {
    global difffilestart ctext cmitmode

    if {$cmitmode eq "tree"} return
    set here [$ctext index @0,0]
    foreach loc $difffilestart {
	if {[$ctext compare $loc > $here]} {
	    $ctext yview $loc
	    return
	}
    }
}

proc clear_ctext {{first 1.0}} {
    global ctext smarktop smarkbot
    global ctext_file_names ctext_file_lines
    global pendinglinks

    set l [lindex [split $first .] 0]
    if {![info exists smarktop] || [$ctext compare $first < $smarktop.0]} {
	set smarktop $l
    }
    if {![info exists smarkbot] || [$ctext compare $first < $smarkbot.0]} {
	set smarkbot $l
    }
    $ctext delete $first end
    if {$first eq "1.0"} {
	catch {unset pendinglinks}
    }
    set ctext_file_names {}
    set ctext_file_lines {}
}

proc settabs {{firstab {}}} {
    global firsttabstop tabstop ctext have_tk85

    if {$firstab ne {} && $have_tk85} {
	set firsttabstop $firstab
    }
    set w [font measure textfont "0"]
    if {$firsttabstop != 0} {
	$ctext conf -tabs [list [expr {($firsttabstop + $tabstop) * $w}] \
			       [expr {($firsttabstop + 2 * $tabstop) * $w}]]
    } elseif {$have_tk85 || $tabstop != 8} {
	$ctext conf -tabs [expr {$tabstop * $w}]
    } else {
	$ctext conf -tabs {}
    }
}

proc incrsearch {name ix op} {
    global ctext searchstring searchdirn

    if {[catch {$ctext index anchor}]} {
	# no anchor set, use start of selection, or of visible area
	set sel [$ctext tag ranges sel]
	if {$sel ne {}} {
	    $ctext mark set anchor [lindex $sel 0]
	} elseif {$searchdirn eq "-forwards"} {
	    $ctext mark set anchor @0,0
	} else {
	    $ctext mark set anchor @0,[winfo height $ctext]
	}
    }
    if {$searchstring ne {}} {
	set here [$ctext search -count mlen $searchdirn -- $searchstring anchor]
	if {$here ne {}} {
	    $ctext see $here
	    set mend "$here + $mlen c"
	    $ctext tag remove sel 1.0 end
	    $ctext tag add sel $here $mend
	    suppress_highlighting_file_for_current_scrollpos
	    highlightfile_for_scrollpos $here
	}
    }
    rehighlight_search_results
}

proc dosearch {} {
    global sstring ctext searchstring searchdirn

    focus $sstring
    $sstring icursor end
    set searchdirn -forwards
    if {$searchstring ne {}} {
	set sel [$ctext tag ranges sel]
	if {$sel ne {}} {
	    set start "[lindex $sel 0] + 1c"
	} elseif {[catch {set start [$ctext index anchor]}]} {
	    set start "@0,0"
	}
	set match [$ctext search -count mlen -- $searchstring $start]
	$ctext tag remove sel 1.0 end
	if {$match eq {}} {
	    bell
	    return
	}
	$ctext see $match
	suppress_highlighting_file_for_current_scrollpos
	highlightfile_for_scrollpos $match
	set mend "$match + $mlen c"
	$ctext tag add sel $match $mend
	$ctext mark unset anchor
	rehighlight_search_results
    }
}

proc dosearchback {} {
    global sstring ctext searchstring searchdirn

    focus $sstring
    $sstring icursor end
    set searchdirn -backwards
    if {$searchstring ne {}} {
	set sel [$ctext tag ranges sel]
	if {$sel ne {}} {
	    set start [lindex $sel 0]
	} elseif {[catch {set start [$ctext index anchor]}]} {
	    set start @0,[winfo height $ctext]
	}
	set match [$ctext search -backwards -count ml -- $searchstring $start]
	$ctext tag remove sel 1.0 end
	if {$match eq {}} {
	    bell
	    return
	}
	$ctext see $match
	suppress_highlighting_file_for_current_scrollpos
	highlightfile_for_scrollpos $match
	set mend "$match + $ml c"
	$ctext tag add sel $match $mend
	$ctext mark unset anchor
	rehighlight_search_results
    }
}

proc rehighlight_search_results {} {
    global ctext searchstring

    $ctext tag remove found 1.0 end
    $ctext tag remove currentsearchhit 1.0 end

    if {$searchstring ne {}} {
	searchmarkvisible 1
    }
}

proc searchmark {first last} {
    global ctext searchstring

    set sel [$ctext tag ranges sel]

    set mend $first.0
    while {1} {
	set match [$ctext search -count mlen -- $searchstring $mend $last.end]
	if {$match eq {}} break
	set mend "$match + $mlen c"
	if {$sel ne {} && [$ctext compare $match == [lindex $sel 0]]} {
	    $ctext tag add currentsearchhit $match $mend
	} else {
	    $ctext tag add found $match $mend
	}
    }
}

proc searchmarkvisible {doall} {
    global ctext smarktop smarkbot

    set topline [lindex [split [$ctext index @0,0] .] 0]
    set botline [lindex [split [$ctext index @0,[winfo height $ctext]] .] 0]
    if {$doall || $botline < $smarktop || $topline > $smarkbot} {
	# no overlap with previous
	searchmark $topline $botline
	set smarktop $topline
	set smarkbot $botline
    } else {
	if {$topline < $smarktop} {
	    searchmark $topline [expr {$smarktop-1}]
	    set smarktop $topline
	}
	if {$botline > $smarkbot} {
	    searchmark [expr {$smarkbot+1}] $botline
	    set smarkbot $botline
	}
    }
}

proc suppress_highlighting_file_for_current_scrollpos {} {
    global ctext suppress_highlighting_file_for_this_scrollpos

    set suppress_highlighting_file_for_this_scrollpos [$ctext index @0,0]
}

proc scrolltext {f0 f1} {
    global searchstring cmitmode ctext
    global suppress_highlighting_file_for_this_scrollpos

    set topidx [$ctext index @0,0]
    if {![info exists suppress_highlighting_file_for_this_scrollpos]
	|| $topidx ne $suppress_highlighting_file_for_this_scrollpos} {
	highlightfile_for_scrollpos $topidx
    }

    catch {unset suppress_highlighting_file_for_this_scrollpos}

    .bleft.bottom.sb set $f0 $f1
    if {$searchstring ne {}} {
	searchmarkvisible 0
    }
}

proc setcoords {} {
    global linespc charspc canvx0 canvy0
    global xspc1 xspc2 lthickness

    set linespc [font metrics mainfont -linespace]
    set charspc [font measure mainfont "m"]
    set canvy0 [expr {int(3 + 0.5 * $linespc)}]
    set canvx0 [expr {int(3 + 0.5 * $linespc)}]
    set lthickness [expr {int($linespc / 9) + 1}]
    set xspc1(0) $linespc
    set xspc2 $linespc
}

proc redisplay {} {
    global canv
    global selectedline

    set ymax [lindex [$canv cget -scrollregion] 3]
    if {$ymax eq {} || $ymax == 0} return
    set span [$canv yview]
    clear_display
    setcanvscroll
    allcanvs yview moveto [lindex $span 0]
    drawvisible
    if {$selectedline ne {}} {
	selectline $selectedline 0
	allcanvs yview moveto [lindex $span 0]
    }
}

proc parsefont {f n} {
    global fontattr

    set fontattr($f,family) [lindex $n 0]
    set s [lindex $n 1]
    if {$s eq {} || $s == 0} {
	set s 10
    } elseif {$s < 0} {
	set s [expr {int(-$s / [winfo fpixels . 1p] + 0.5)}]
    }
    set fontattr($f,size) $s
    set fontattr($f,weight) normal
    set fontattr($f,slant) roman
    foreach style [lrange $n 2 end] {
	switch -- $style {
	    "normal" -
	    "bold"   {set fontattr($f,weight) $style}
	    "roman" -
	    "italic" {set fontattr($f,slant) $style}
	}
    }
}

proc fontflags {f {isbold 0}} {
    global fontattr

    return [list -family $fontattr($f,family) -size $fontattr($f,size) \
		-weight [expr {$isbold? "bold": $fontattr($f,weight)}] \
		-slant $fontattr($f,slant)]
}

proc fontname {f} {
    global fontattr

    set n [list $fontattr($f,family) $fontattr($f,size)]
    if {$fontattr($f,weight) eq "bold"} {
	lappend n "bold"
    }
    if {$fontattr($f,slant) eq "italic"} {
	lappend n "italic"
    }
    return $n
}

proc incrfont {inc} {
    global mainfont textfont ctext canv cflist showrefstop
    global stopped entries fontattr

    unmarkmatches
    set s $fontattr(mainfont,size)
    incr s $inc
    if {$s < 1} {
	set s 1
    }
    set fontattr(mainfont,size) $s
    font config mainfont -size $s
    font config mainfontbold -size $s
    set mainfont [fontname mainfont]
    set s $fontattr(textfont,size)
    incr s $inc
    if {$s < 1} {
	set s 1
    }
    set fontattr(textfont,size) $s
    font config textfont -size $s
    font config textfontbold -size $s
    set textfont [fontname textfont]
    setcoords
    settabs
    redisplay
}

proc clearsha1 {} {
    global sha1entry sha1string
    if {[string length $sha1string] == 40} {
	$sha1entry delete 0 end
    }
}

proc sha1change {n1 n2 op} {
    global sha1string currentid sha1but
    if {$sha1string == {}
	|| ([info exists currentid] && $sha1string == $currentid)} {
	set state disabled
    } else {
	set state normal
    }
    if {[$sha1but cget -state] == $state} return
    if {$state == "normal"} {
	$sha1but conf -state normal -relief raised -text "[mc "Goto:"] "
    } else {
	$sha1but conf -state disabled -relief flat -text "[mc "SHA1 ID:"] "
    }
}

proc gotocommit {} {
    global sha1string tagids headids curview varcid

    if {$sha1string == {}
	|| ([info exists currentid] && $sha1string == $currentid)} return
    if {[info exists tagids($sha1string)]} {
	set id $tagids($sha1string)
    } elseif {[info exists headids($sha1string)]} {
	set id $headids($sha1string)
    } else {
	set id [string tolower $sha1string]
	if {[regexp {^[0-9a-f]{4,39}$} $id]} {
	    set matches [longid $id]
	    if {$matches ne {}} {
		if {[llength $matches] > 1} {
		    error_popup [mc "Short SHA1 id %s is ambiguous" $id]
		    return
		}
		set id [lindex $matches 0]
	    }
	} else {
	    if {[catch {set id [exec git rev-parse --verify $sha1string]}]} {
		error_popup [mc "Revision %s is not known" $sha1string]
		return
	    }
	}
    }
    if {[commitinview $id $curview]} {
	selectline [rowofcommit $id] 1
	return
    }
    if {[regexp {^[0-9a-fA-F]{4,}$} $sha1string]} {
	set msg [mc "SHA1 id %s is not known" $sha1string]
    } else {
	set msg [mc "Revision %s is not in the current view" $sha1string]
    }
    error_popup $msg
}

proc lineenter {x y id} {
    global hoverx hovery hoverid hovertimer
    global commitinfo canv

    if {![info exists commitinfo($id)] && ![getcommit $id]} return
    set hoverx $x
    set hovery $y
    set hoverid $id
    if {[info exists hovertimer]} {
	after cancel $hovertimer
    }
    set hovertimer [after 500 linehover]
    $canv delete hover
}

proc linemotion {x y id} {
    global hoverx hovery hoverid hovertimer

    if {[info exists hoverid] && $id == $hoverid} {
	set hoverx $x
	set hovery $y
	if {[info exists hovertimer]} {
	    after cancel $hovertimer
	}
	set hovertimer [after 500 linehover]
    }
}

proc lineleave {id} {
    global hoverid hovertimer canv

    if {[info exists hoverid] && $id == $hoverid} {
	$canv delete hover
	if {[info exists hovertimer]} {
	    after cancel $hovertimer
	    unset hovertimer
	}
	unset hoverid
    }
}

proc linehover {} {
    global hoverx hovery hoverid hovertimer
    global canv linespc lthickness
    global linehoverbgcolor linehoverfgcolor linehoveroutlinecolor

    global commitinfo

    set text [lindex $commitinfo($hoverid) 0]
    set ymax [lindex [$canv cget -scrollregion] 3]
    if {$ymax == {}} return
    set yfrac [lindex [$canv yview] 0]
    set x [expr {$hoverx + 2 * $linespc}]
    set y [expr {$hovery + $yfrac * $ymax - $linespc / 2}]
    set x0 [expr {$x - 2 * $lthickness}]
    set y0 [expr {$y - 2 * $lthickness}]
    set x1 [expr {$x + [font measure mainfont $text] + 2 * $lthickness}]
    set y1 [expr {$y + $linespc + 2 * $lthickness}]
    set t [$canv create rectangle $x0 $y0 $x1 $y1 \
	       -fill $linehoverbgcolor -outline $linehoveroutlinecolor \
	       -width 1 -tags hover]
    $canv raise $t
    set t [$canv create text $x $y -anchor nw -text $text -tags hover \
	       -font mainfont -fill $linehoverfgcolor]
    $canv raise $t
}

proc clickisonarrow {id y} {
    global lthickness

    set ranges [rowranges $id]
    set thresh [expr {2 * $lthickness + 6}]
    set n [expr {[llength $ranges] - 1}]
    for {set i 1} {$i < $n} {incr i} {
	set row [lindex $ranges $i]
	if {abs([yc $row] - $y) < $thresh} {
	    return $i
	}
    }
    return {}
}

proc arrowjump {id n y} {
    global canv

    # 1 <-> 2, 3 <-> 4, etc...
    set n [expr {(($n - 1) ^ 1) + 1}]
    set row [lindex [rowranges $id] $n]
    set yt [yc $row]
    set ymax [lindex [$canv cget -scrollregion] 3]
    if {$ymax eq {} || $ymax <= 0} return
    set view [$canv yview]
    set yspan [expr {[lindex $view 1] - [lindex $view 0]}]
    set yfrac [expr {$yt / $ymax - $yspan / 2}]
    if {$yfrac < 0} {
	set yfrac 0
    }
    allcanvs yview moveto $yfrac
}

proc lineclick {x y id isnew} {
    global ctext commitinfo children canv thickerline curview

    if {![info exists commitinfo($id)] && ![getcommit $id]} return
    unmarkmatches
    unselectline
    normalline
    $canv delete hover
    # draw this line thicker than normal
    set thickerline $id
    drawlines $id
    if {$isnew} {
	set ymax [lindex [$canv cget -scrollregion] 3]
	if {$ymax eq {}} return
	set yfrac [lindex [$canv yview] 0]
	set y [expr {$y + $yfrac * $ymax}]
    }
    set dirn [clickisonarrow $id $y]
    if {$dirn ne {}} {
	arrowjump $id $dirn $y
	return
    }

    if {$isnew} {
	addtohistory [list lineclick $x $y $id 0] savectextpos
    }
    # fill the details pane with info about this line
    $ctext conf -state normal
    clear_ctext
    settabs 0
    $ctext insert end "[mc "Parent"]:\t"
    $ctext insert end $id link0
    setlink $id link0
    set info $commitinfo($id)
    $ctext insert end "\n\t[lindex $info 0]\n"
    $ctext insert end "\t[mc "Author"]:\t[lindex $info 1]\n"
    set date [formatdate [lindex $info 2]]
    $ctext insert end "\t[mc "Date"]:\t$date\n"
    set kids $children($curview,$id)
    if {$kids ne {}} {
	$ctext insert end "\n[mc "Children"]:"
	set i 0
	foreach child $kids {
	    incr i
	    if {![info exists commitinfo($child)] && ![getcommit $child]} continue
	    set info $commitinfo($child)
	    $ctext insert end "\n\t"
	    $ctext insert end $child link$i
	    setlink $child link$i
	    $ctext insert end "\n\t[lindex $info 0]"
	    $ctext insert end "\n\t[mc "Author"]:\t[lindex $info 1]"
	    set date [formatdate [lindex $info 2]]
	    $ctext insert end "\n\t[mc "Date"]:\t$date\n"
	}
    }
    maybe_scroll_ctext 1
    $ctext conf -state disabled
    init_flist {}
}

proc normalline {} {
    global thickerline
    if {[info exists thickerline]} {
	set id $thickerline
	unset thickerline
	drawlines $id
    }
}

proc selbyid {id {isnew 1}} {
    global curview
    if {[commitinview $id $curview]} {
	selectline [rowofcommit $id] $isnew
    }
}

proc mstime {} {
    global startmstime
    if {![info exists startmstime]} {
	set startmstime [clock clicks -milliseconds]
    }
    return [format "%.3f" [expr {([clock click -milliseconds] - $startmstime) / 1000.0}]]
}

proc rowmenu {x y id} {
    global rowctxmenu selectedline rowmenuid curview
    global nullid nullid2 fakerowmenu mainhead markedid

    stopfinding
    set rowmenuid $id
    if {$selectedline eq {} || [rowofcommit $id] eq $selectedline} {
	set state disabled
    } else {
	set state normal
    }
    if {[info exists markedid] && $markedid ne $id} {
	set mstate normal
    } else {
	set mstate disabled
    }
    if {$id ne $nullid && $id ne $nullid2} {
	set menu $rowctxmenu
	if {$mainhead ne {}} {
	    $menu entryconfigure 7 -label [mc "Reset %s branch to here" $mainhead] -state normal
	} else {
	    $menu entryconfigure 7 -label [mc "Detached head: can't reset" $mainhead] -state disabled
	}
	$menu entryconfigure 9 -state $mstate
	$menu entryconfigure 10 -state $mstate
	$menu entryconfigure 11 -state $mstate
    } else {
	set menu $fakerowmenu
    }
    $menu entryconfigure [mca "Diff this -> selected"] -state $state
    $menu entryconfigure [mca "Diff selected -> this"] -state $state
    $menu entryconfigure [mca "Make patch"] -state $state
    $menu entryconfigure [mca "Diff this -> marked commit"] -state $mstate
    $menu entryconfigure [mca "Diff marked commit -> this"] -state $mstate
    tk_popup $menu $x $y
}

proc markhere {} {
    global rowmenuid markedid canv

    set markedid $rowmenuid
    make_idmark $markedid
}

proc gotomark {} {
    global markedid

    if {[info exists markedid]} {
	selbyid $markedid
    }
}

proc replace_by_kids {l r} {
    global curview children

    set id [commitonrow $r]
    set l [lreplace $l 0 0]
    foreach kid $children($curview,$id) {
	lappend l [rowofcommit $kid]
    }
    return [lsort -integer -decreasing -unique $l]
}

proc find_common_desc {} {
    global markedid rowmenuid curview children

    if {![info exists markedid]} return
    if {![commitinview $markedid $curview] ||
	![commitinview $rowmenuid $curview]} return
    #set t1 [clock clicks -milliseconds]
    set l1 [list [rowofcommit $markedid]]
    set l2 [list [rowofcommit $rowmenuid]]
    while 1 {
	set r1 [lindex $l1 0]
	set r2 [lindex $l2 0]
	if {$r1 eq {} || $r2 eq {}} break
	if {$r1 == $r2} {
	    selectline $r1 1
	    break
	}
	if {$r1 > $r2} {
	    set l1 [replace_by_kids $l1 $r1]
	} else {
	    set l2 [replace_by_kids $l2 $r2]
	}
    }
    #set t2 [clock clicks -milliseconds]
    #puts "took [expr {$t2-$t1}]ms"
}

proc compare_commits {} {
    global markedid rowmenuid curview children

    if {![info exists markedid]} return
    if {![commitinview $markedid $curview]} return
    addtohistory [list do_cmp_commits $markedid $rowmenuid]
    do_cmp_commits $markedid $rowmenuid
}

proc getpatchid {id} {
    global patchids

    if {![info exists patchids($id)]} {
	set cmd [diffcmd [list $id] {-p --root}]
	# trim off the initial "|"
	set cmd [lrange $cmd 1 end]
	if {[catch {
	    set x [eval exec $cmd | git patch-id]
	    set patchids($id) [lindex $x 0]
	}]} {
	    set patchids($id) "error"
	}
    }
    return $patchids($id)
}

proc do_cmp_commits {a b} {
    global ctext curview parents children patchids commitinfo

    $ctext conf -state normal
    clear_ctext
    init_flist {}
    for {set i 0} {$i < 100} {incr i} {
	set skipa 0
	set skipb 0
	if {[llength $parents($curview,$a)] > 1} {
	    appendshortlink $a [mc "Skipping merge commit "] "\n"
	    set skipa 1
	} else {
	    set patcha [getpatchid $a]
	}
	if {[llength $parents($curview,$b)] > 1} {
	    appendshortlink $b [mc "Skipping merge commit "] "\n"
	    set skipb 1
	} else {
	    set patchb [getpatchid $b]
	}
	if {!$skipa && !$skipb} {
	    set heada [lindex $commitinfo($a) 0]
	    set headb [lindex $commitinfo($b) 0]
	    if {$patcha eq "error"} {
		appendshortlink $a [mc "Error getting patch ID for "] \
		    [mc " - stopping\n"]
		break
	    }
	    if {$patchb eq "error"} {
		appendshortlink $b [mc "Error getting patch ID for "] \
		    [mc " - stopping\n"]
		break
	    }
	    if {$patcha eq $patchb} {
		if {$heada eq $headb} {
		    appendshortlink $a [mc "Commit "]
		    appendshortlink $b " == " "  $heada\n"
		} else {
		    appendshortlink $a [mc "Commit "] "  $heada\n"
		    appendshortlink $b [mc " is the same patch as\n       "] \
			"  $headb\n"
		}
		set skipa 1
		set skipb 1
	    } else {
		$ctext insert end "\n"
		appendshortlink $a [mc "Commit "] "  $heada\n"
		appendshortlink $b [mc " differs from\n       "] \
		    "  $headb\n"
		$ctext insert end [mc "Diff of commits:\n\n"]
		$ctext conf -state disabled
		update
		diffcommits $a $b
		return
	    }
	}
	if {$skipa} {
	    set kids [real_children $curview,$a]
	    if {[llength $kids] != 1} {
		$ctext insert end "\n"
		appendshortlink $a [mc "Commit "] \
		    [mc " has %s children - stopping\n" [llength $kids]]
		break
	    }
	    set a [lindex $kids 0]
	}
	if {$skipb} {
	    set kids [real_children $curview,$b]
	    if {[llength $kids] != 1} {
		appendshortlink $b [mc "Commit "] \
		    [mc " has %s children - stopping\n" [llength $kids]]
		break
	    }
	    set b [lindex $kids 0]
	}
    }
    $ctext conf -state disabled
}

proc diffcommits {a b} {
    global diffcontext diffids blobdifffd diffinhdr currdiffsubmod

    set tmpdir [gitknewtmpdir]
    set fna [file join $tmpdir "commit-[string range $a 0 7]"]
    set fnb [file join $tmpdir "commit-[string range $b 0 7]"]
    if {[catch {
	exec git diff-tree -p --pretty $a >$fna
	exec git diff-tree -p --pretty $b >$fnb
    } err]} {
	error_popup [mc "Error writing commit to file: %s" $err]
	return
    }
    if {[catch {
	set fd [open "| diff -U$diffcontext $fna $fnb" r]
    } err]} {
	error_popup [mc "Error diffing commits: %s" $err]
	return
    }
    set diffids [list commits $a $b]
    set blobdifffd($diffids) $fd
    set diffinhdr 0
    set currdiffsubmod ""
    filerun $fd [list getblobdiffline $fd $diffids]
}

proc diffvssel {dirn} {
    global rowmenuid selectedline

    if {$selectedline eq {}} return
    if {$dirn} {
	set oldid [commitonrow $selectedline]
	set newid $rowmenuid
    } else {
	set oldid $rowmenuid
	set newid [commitonrow $selectedline]
    }
    addtohistory [list doseldiff $oldid $newid] savectextpos
    doseldiff $oldid $newid
}

proc diffvsmark {dirn} {
    global rowmenuid markedid

    if {![info exists markedid]} return
    if {$dirn} {
	set oldid $markedid
	set newid $rowmenuid
    } else {
	set oldid $rowmenuid
	set newid $markedid
    }
    addtohistory [list doseldiff $oldid $newid] savectextpos
    doseldiff $oldid $newid
}

proc doseldiff {oldid newid} {
    global ctext
    global commitinfo

    $ctext conf -state normal
    clear_ctext
    init_flist [mc "Top"]
    $ctext insert end "[mc "From"] "
    $ctext insert end $oldid link0
    setlink $oldid link0
    $ctext insert end "\n     "
    $ctext insert end [lindex $commitinfo($oldid) 0]
    $ctext insert end "\n\n[mc "To"]   "
    $ctext insert end $newid link1
    setlink $newid link1
    $ctext insert end "\n     "
    $ctext insert end [lindex $commitinfo($newid) 0]
    $ctext insert end "\n"
    $ctext conf -state disabled
    $ctext tag remove found 1.0 end
    startdiff [list $oldid $newid]
}

proc mkpatch {} {
    global rowmenuid currentid commitinfo patchtop patchnum NS

    if {![info exists currentid]} return
    set oldid $currentid
    set oldhead [lindex $commitinfo($oldid) 0]
    set newid $rowmenuid
    set newhead [lindex $commitinfo($newid) 0]
    set top .patch
    set patchtop $top
    catch {destroy $top}
    ttk_toplevel $top
    make_transient $top .
    ${NS}::label $top.title -text [mc "Generate patch"]
    grid $top.title - -pady 10
    ${NS}::label $top.from -text [mc "From:"]
    ${NS}::entry $top.fromsha1 -width 40
    $top.fromsha1 insert 0 $oldid
    $top.fromsha1 conf -state readonly
    grid $top.from $top.fromsha1 -sticky w
    ${NS}::entry $top.fromhead -width 60
    $top.fromhead insert 0 $oldhead
    $top.fromhead conf -state readonly
    grid x $top.fromhead -sticky w
    ${NS}::label $top.to -text [mc "To:"]
    ${NS}::entry $top.tosha1 -width 40
    $top.tosha1 insert 0 $newid
    $top.tosha1 conf -state readonly
    grid $top.to $top.tosha1 -sticky w
    ${NS}::entry $top.tohead -width 60
    $top.tohead insert 0 $newhead
    $top.tohead conf -state readonly
    grid x $top.tohead -sticky w
    ${NS}::button $top.rev -text [mc "Reverse"] -command mkpatchrev
    grid $top.rev x -pady 10 -padx 5
    ${NS}::label $top.flab -text [mc "Output file:"]
    ${NS}::entry $top.fname -width 60
    $top.fname insert 0 [file normalize "patch$patchnum.patch"]
    incr patchnum
    grid $top.flab $top.fname -sticky w
    ${NS}::frame $top.buts
    ${NS}::button $top.buts.gen -text [mc "Generate"] -command mkpatchgo
    ${NS}::button $top.buts.can -text [mc "Cancel"] -command mkpatchcan
    bind $top <Key-Return> mkpatchgo
    bind $top <Key-Escape> mkpatchcan
    grid $top.buts.gen $top.buts.can
    grid columnconfigure $top.buts 0 -weight 1 -uniform a
    grid columnconfigure $top.buts 1 -weight 1 -uniform a
    grid $top.buts - -pady 10 -sticky ew
    focus $top.fname
}

proc mkpatchrev {} {
    global patchtop

    set oldid [$patchtop.fromsha1 get]
    set oldhead [$patchtop.fromhead get]
    set newid [$patchtop.tosha1 get]
    set newhead [$patchtop.tohead get]
    foreach e [list fromsha1 fromhead tosha1 tohead] \
	    v [list $newid $newhead $oldid $oldhead] {
	$patchtop.$e conf -state normal
	$patchtop.$e delete 0 end
	$patchtop.$e insert 0 $v
	$patchtop.$e conf -state readonly
    }
}

proc mkpatchgo {} {
    global patchtop nullid nullid2

    set oldid [$patchtop.fromsha1 get]
    set newid [$patchtop.tosha1 get]
    set fname [$patchtop.fname get]
    set cmd [diffcmd [list $oldid $newid] -p]
    # trim off the initial "|"
    set cmd [lrange $cmd 1 end]
    lappend cmd >$fname &
    if {[catch {eval exec $cmd} err]} {
	error_popup "[mc "Error creating patch:"] $err" $patchtop
    }
    catch {destroy $patchtop}
    unset patchtop
}

proc mkpatchcan {} {
    global patchtop

    catch {destroy $patchtop}
    unset patchtop
}

proc mktag {} {
    global rowmenuid mktagtop commitinfo NS

    set top .maketag
    set mktagtop $top
    catch {destroy $top}
    ttk_toplevel $top
    make_transient $top .
    ${NS}::label $top.title -text [mc "Create tag"]
    grid $top.title - -pady 10
    ${NS}::label $top.id -text [mc "ID:"]
    ${NS}::entry $top.sha1 -width 40
    $top.sha1 insert 0 $rowmenuid
    $top.sha1 conf -state readonly
    grid $top.id $top.sha1 -sticky w
    ${NS}::entry $top.head -width 60
    $top.head insert 0 [lindex $commitinfo($rowmenuid) 0]
    $top.head conf -state readonly
    grid x $top.head -sticky w
    ${NS}::label $top.tlab -text [mc "Tag name:"]
    ${NS}::entry $top.tag -width 60
    grid $top.tlab $top.tag -sticky w
    ${NS}::label $top.op -text [mc "Tag message is optional"]
    grid $top.op -columnspan 2 -sticky we
    ${NS}::label $top.mlab -text [mc "Tag message:"]
    ${NS}::entry $top.msg -width 60
    grid $top.mlab $top.msg -sticky w
    ${NS}::frame $top.buts
    ${NS}::button $top.buts.gen -text [mc "Create"] -command mktaggo
    ${NS}::button $top.buts.can -text [mc "Cancel"] -command mktagcan
    bind $top <Key-Return> mktaggo
    bind $top <Key-Escape> mktagcan
    grid $top.buts.gen $top.buts.can
    grid columnconfigure $top.buts 0 -weight 1 -uniform a
    grid columnconfigure $top.buts 1 -weight 1 -uniform a
    grid $top.buts - -pady 10 -sticky ew
    focus $top.tag
}

proc domktag {} {
    global mktagtop env tagids idtags

    set id [$mktagtop.sha1 get]
    set tag [$mktagtop.tag get]
    set msg [$mktagtop.msg get]
    if {$tag == {}} {
	error_popup [mc "No tag name specified"] $mktagtop
	return 0
    }
    if {[info exists tagids($tag)]} {
	error_popup [mc "Tag \"%s\" already exists" $tag] $mktagtop
	return 0
    }
    if {[catch {
	if {$msg != {}} {
	    exec git tag -a -m $msg $tag $id
	} else {
	    exec git tag $tag $id
	}
    } err]} {
	error_popup "[mc "Error creating tag:"] $err" $mktagtop
	return 0
    }

    set tagids($tag) $id
    lappend idtags($id) $tag
    redrawtags $id
    addedtag $id
    dispneartags 0
    run refill_reflist
    return 1
}

proc redrawtags {id} {
    global canv linehtag idpos currentid curview cmitlisted markedid
    global canvxmax iddrawn circleitem mainheadid circlecolors
    global mainheadcirclecolor

    if {![commitinview $id $curview]} return
    if {![info exists iddrawn($id)]} return
    set row [rowofcommit $id]
    if {$id eq $mainheadid} {
	set ofill $mainheadcirclecolor
    } else {
	set ofill [lindex $circlecolors $cmitlisted($curview,$id)]
    }
    $canv itemconf $circleitem($row) -fill $ofill
    $canv delete tag.$id
    set xt [eval drawtags $id $idpos($id)]
    $canv coords $linehtag($id) $xt [lindex $idpos($id) 2]
    set text [$canv itemcget $linehtag($id) -text]
    set font [$canv itemcget $linehtag($id) -font]
    set xr [expr {$xt + [font measure $font $text]}]
    if {$xr > $canvxmax} {
	set canvxmax $xr
	setcanvscroll
    }
    if {[info exists currentid] && $currentid == $id} {
	make_secsel $id
    }
    if {[info exists markedid] && $markedid eq $id} {
	make_idmark $id
    }
}

proc mktagcan {} {
    global mktagtop

    catch {destroy $mktagtop}
    unset mktagtop
}

proc mktaggo {} {
    if {![domktag]} return
    mktagcan
}

proc writecommit {} {
    global rowmenuid wrcomtop commitinfo wrcomcmd NS

    set top .writecommit
    set wrcomtop $top
    catch {destroy $top}
    ttk_toplevel $top
    make_transient $top .
    ${NS}::label $top.title -text [mc "Write commit to file"]
    grid $top.title - -pady 10
    ${NS}::label $top.id -text [mc "ID:"]
    ${NS}::entry $top.sha1 -width 40
    $top.sha1 insert 0 $rowmenuid
    $top.sha1 conf -state readonly
    grid $top.id $top.sha1 -sticky w
    ${NS}::entry $top.head -width 60
    $top.head insert 0 [lindex $commitinfo($rowmenuid) 0]
    $top.head conf -state readonly
    grid x $top.head -sticky w
    ${NS}::label $top.clab -text [mc "Command:"]
    ${NS}::entry $top.cmd -width 60 -textvariable wrcomcmd
    grid $top.clab $top.cmd -sticky w -pady 10
    ${NS}::label $top.flab -text [mc "Output file:"]
    ${NS}::entry $top.fname -width 60
    $top.fname insert 0 [file normalize "commit-[string range $rowmenuid 0 6]"]
    grid $top.flab $top.fname -sticky w
    ${NS}::frame $top.buts
    ${NS}::button $top.buts.gen -text [mc "Write"] -command wrcomgo
    ${NS}::button $top.buts.can -text [mc "Cancel"] -command wrcomcan
    bind $top <Key-Return> wrcomgo
    bind $top <Key-Escape> wrcomcan
    grid $top.buts.gen $top.buts.can
    grid columnconfigure $top.buts 0 -weight 1 -uniform a
    grid columnconfigure $top.buts 1 -weight 1 -uniform a
    grid $top.buts - -pady 10 -sticky ew
    focus $top.fname
}

proc wrcomgo {} {
    global wrcomtop

    set id [$wrcomtop.sha1 get]
    set cmd "echo $id | [$wrcomtop.cmd get]"
    set fname [$wrcomtop.fname get]
    if {[catch {exec sh -c $cmd >$fname &} err]} {
	error_popup "[mc "Error writing commit:"] $err" $wrcomtop
    }
    catch {destroy $wrcomtop}
    unset wrcomtop
}

proc wrcomcan {} {
    global wrcomtop

    catch {destroy $wrcomtop}
    unset wrcomtop
}

proc mkbranch {} {
    global rowmenuid mkbrtop NS

    set top .makebranch
    catch {destroy $top}
    ttk_toplevel $top
    make_transient $top .
    ${NS}::label $top.title -text [mc "Create new branch"]
    grid $top.title - -pady 10
    ${NS}::label $top.id -text [mc "ID:"]
    ${NS}::entry $top.sha1 -width 40
    $top.sha1 insert 0 $rowmenuid
    $top.sha1 conf -state readonly
    grid $top.id $top.sha1 -sticky w
    ${NS}::label $top.nlab -text [mc "Name:"]
    ${NS}::entry $top.name -width 40
    grid $top.nlab $top.name -sticky w
    ${NS}::frame $top.buts
    ${NS}::button $top.buts.go -text [mc "Create"] -command [list mkbrgo $top]
    ${NS}::button $top.buts.can -text [mc "Cancel"] -command "catch {destroy $top}"
    bind $top <Key-Return> [list mkbrgo $top]
    bind $top <Key-Escape> "catch {destroy $top}"
    grid $top.buts.go $top.buts.can
    grid columnconfigure $top.buts 0 -weight 1 -uniform a
    grid columnconfigure $top.buts 1 -weight 1 -uniform a
    grid $top.buts - -pady 10 -sticky ew
    focus $top.name
}

proc mkbrgo {top} {
    global headids idheads

    set name [$top.name get]
    set id [$top.sha1 get]
    set cmdargs {}
    set old_id {}
    if {$name eq {}} {
	error_popup [mc "Please specify a name for the new branch"] $top
	return
    }
    if {[info exists headids($name)]} {
	if {![confirm_popup [mc \
		"Branch '%s' already exists. Overwrite?" $name] $top]} {
	    return
	}
	set old_id $headids($name)
	lappend cmdargs -f
    }
    catch {destroy $top}
    lappend cmdargs $name $id
    nowbusy newbranch
    update
    if {[catch {
	eval exec git branch $cmdargs
    } err]} {
	notbusy newbranch
	error_popup $err
    } else {
	notbusy newbranch
	if {$old_id ne {}} {
	    movehead $id $name
	    movedhead $id $name
	    redrawtags $old_id
	    redrawtags $id
	} else {
	    set headids($name) $id
	    lappend idheads($id) $name
	    addedhead $id $name
	    redrawtags $id
	}
	dispneartags 0
	run refill_reflist
    }
}

proc exec_citool {tool_args {baseid {}}} {
    global commitinfo env

    set save_env [array get env GIT_AUTHOR_*]

    if {$baseid ne {}} {
	if {![info exists commitinfo($baseid)]} {
	    getcommit $baseid
	}
	set author [lindex $commitinfo($baseid) 1]
	set date [lindex $commitinfo($baseid) 2]
	if {[regexp {^\s*(\S.*\S|\S)\s*<(.*)>\s*$} \
	            $author author name email]
	    && $date ne {}} {
	    set env(GIT_AUTHOR_NAME) $name
	    set env(GIT_AUTHOR_EMAIL) $email
	    set env(GIT_AUTHOR_DATE) $date
	}
    }

    eval exec git citool $tool_args &

    array unset env GIT_AUTHOR_*
    array set env $save_env
}

proc cherrypick {} {
    global rowmenuid curview
    global mainhead mainheadid
    global gitdir

    set oldhead [exec git rev-parse HEAD]
    set dheads [descheads $rowmenuid]
    if {$dheads ne {} && [lsearch -exact $dheads $oldhead] >= 0} {
	set ok [confirm_popup [mc "Commit %s is already\
		included in branch %s -- really re-apply it?" \
				   [string range $rowmenuid 0 7] $mainhead]]
	if {!$ok} return
    }
    nowbusy cherrypick [mc "Cherry-picking"]
    update
    # Unfortunately git-cherry-pick writes stuff to stderr even when
    # no error occurs, and exec takes that as an indication of error...
    if {[catch {exec sh -c "git cherry-pick -r $rowmenuid 2>&1"} err]} {
	notbusy cherrypick
	if {[regexp -line \
		 {Entry '(.*)' (would be overwritten by merge|not uptodate)} \
		 $err msg fname]} {
	    error_popup [mc "Cherry-pick failed because of local changes\
			to file '%s'.\nPlease commit, reset or stash\
			your changes and try again." $fname]
	} elseif {[regexp -line \
		       {^(CONFLICT \(.*\):|Automatic cherry-pick failed|error: could not apply)} \
		       $err]} {
	    if {[confirm_popup [mc "Cherry-pick failed because of merge\
			conflict.\nDo you wish to run git citool to\
			resolve it?"]]} {
		# Force citool to read MERGE_MSG
		file delete [file join $gitdir "GITGUI_MSG"]
		exec_citool {} $rowmenuid
	    }
	} else {
	    error_popup $err
	}
	run updatecommits
	return
    }
    set newhead [exec git rev-parse HEAD]
    if {$newhead eq $oldhead} {
	notbusy cherrypick
	error_popup [mc "No changes committed"]
	return
    }
    addnewchild $newhead $oldhead
    if {[commitinview $oldhead $curview]} {
	# XXX this isn't right if we have a path limit...
	insertrow $newhead $oldhead $curview
	if {$mainhead ne {}} {
	    movehead $newhead $mainhead
	    movedhead $newhead $mainhead
	}
	set mainheadid $newhead
	redrawtags $oldhead
	redrawtags $newhead
	selbyid $newhead
    }
    notbusy cherrypick
}

proc revert {} {
    global rowmenuid curview
    global mainhead mainheadid
    global gitdir

    set oldhead [exec git rev-parse HEAD]
    set dheads [descheads $rowmenuid]
    if { $dheads eq {} || [lsearch -exact $dheads $oldhead] == -1 } {
       set ok [confirm_popup [mc "Commit %s is not\
           included in branch %s -- really revert it?" \
                      [string range $rowmenuid 0 7] $mainhead]]
       if {!$ok} return
    }
    nowbusy revert [mc "Reverting"]
    update

    if [catch {exec git revert --no-edit $rowmenuid} err] {
        notbusy revert
        if [regexp {files would be overwritten by merge:(\n(( |\t)+[^\n]+\n)+)}\
                $err match files] {
            regsub {\n( |\t)+} $files "\n" files
            error_popup [mc "Revert failed because of local changes to\
                the following files:%s Please commit, reset or stash \
                your changes and try again." $files]
        } elseif [regexp {error: could not revert} $err] {
            if [confirm_popup [mc "Revert failed because of merge conflict.\n\
                Do you wish to run git citool to resolve it?"]] {
                # Force citool to read MERGE_MSG
                file delete [file join $gitdir "GITGUI_MSG"]
                exec_citool {} $rowmenuid
            }
        } else { error_popup $err }
        run updatecommits
        return
    }

    set newhead [exec git rev-parse HEAD]
    if { $newhead eq $oldhead } {
        notbusy revert
        error_popup [mc "No changes committed"]
        return
    }

    addnewchild $newhead $oldhead

    if [commitinview $oldhead $curview] {
        # XXX this isn't right if we have a path limit...
        insertrow $newhead $oldhead $curview
        if {$mainhead ne {}} {
            movehead $newhead $mainhead
            movedhead $newhead $mainhead
        }
        set mainheadid $newhead
        redrawtags $oldhead
        redrawtags $newhead
        selbyid $newhead
    }

    notbusy revert
}

proc resethead {} {
    global mainhead rowmenuid confirm_ok resettype NS

    set confirm_ok 0
    set w ".confirmreset"
    ttk_toplevel $w
    make_transient $w .
    wm title $w [mc "Confirm reset"]
    ${NS}::label $w.m -text \
	[mc "Reset branch %s to %s?" $mainhead [string range $rowmenuid 0 7]]
    pack $w.m -side top -fill x -padx 20 -pady 20
    ${NS}::labelframe $w.f -text [mc "Reset type:"]
    set resettype mixed
    ${NS}::radiobutton $w.f.soft -value soft -variable resettype \
	-text [mc "Soft: Leave working tree and index untouched"]
    grid $w.f.soft -sticky w
    ${NS}::radiobutton $w.f.mixed -value mixed -variable resettype \
	-text [mc "Mixed: Leave working tree untouched, reset index"]
    grid $w.f.mixed -sticky w
    ${NS}::radiobutton $w.f.hard -value hard -variable resettype \
	-text [mc "Hard: Reset working tree and index\n(discard ALL local changes)"]
    grid $w.f.hard -sticky w
    pack $w.f -side top -fill x -padx 4
    ${NS}::button $w.ok -text [mc OK] -command "set confirm_ok 1; destroy $w"
    pack $w.ok -side left -fill x -padx 20 -pady 20
    ${NS}::button $w.cancel -text [mc Cancel] -command "destroy $w"
    bind $w <Key-Escape> [list destroy $w]
    pack $w.cancel -side right -fill x -padx 20 -pady 20
    bind $w <Visibility> "grab $w; focus $w"
    tkwait window $w
    if {!$confirm_ok} return
    if {[catch {set fd [open \
	    [list | git reset --$resettype $rowmenuid 2>@1] r]} err]} {
	error_popup $err
    } else {
	dohidelocalchanges
	filerun $fd [list readresetstat $fd]
	nowbusy reset [mc "Resetting"]
	selbyid $rowmenuid
    }
}

proc readresetstat {fd} {
    global mainhead mainheadid showlocalchanges rprogcoord

    if {[gets $fd line] >= 0} {
	if {[regexp {([0-9]+)% \(([0-9]+)/([0-9]+)\)} $line match p m n]} {
	    set rprogcoord [expr {1.0 * $m / $n}]
	    adjustprogress
	}
	return 1
    }
    set rprogcoord 0
    adjustprogress
    notbusy reset
    if {[catch {close $fd} err]} {
	error_popup $err
    }
    set oldhead $mainheadid
    set newhead [exec git rev-parse HEAD]
    if {$newhead ne $oldhead} {
	movehead $newhead $mainhead
	movedhead $newhead $mainhead
	set mainheadid $newhead
	redrawtags $oldhead
	redrawtags $newhead
    }
    if {$showlocalchanges} {
	doshowlocalchanges
    }
    return 0
}

# context menu for a head
proc headmenu {x y id head} {
    global headmenuid headmenuhead headctxmenu mainhead

    stopfinding
    set headmenuid $id
    set headmenuhead $head
    set state normal
    if {[string match "remotes/*" $head]} {
	set state disabled
    }
    if {$head eq $mainhead} {
	set state disabled
    }
    $headctxmenu entryconfigure 0 -state $state
    $headctxmenu entryconfigure 1 -state $state
    tk_popup $headctxmenu $x $y
}

proc cobranch {} {
    global headmenuid headmenuhead headids
    global showlocalchanges

    # check the tree is clean first??
    nowbusy checkout [mc "Checking out"]
    update
    dohidelocalchanges
    if {[catch {
	set fd [open [list | git checkout $headmenuhead 2>@1] r]
    } err]} {
	notbusy checkout
	error_popup $err
	if {$showlocalchanges} {
	    dodiffindex
	}
    } else {
	filerun $fd [list readcheckoutstat $fd $headmenuhead $headmenuid]
    }
}

proc readcheckoutstat {fd newhead newheadid} {
    global mainhead mainheadid headids showlocalchanges progresscoords
    global viewmainheadid curview

    if {[gets $fd line] >= 0} {
	if {[regexp {([0-9]+)% \(([0-9]+)/([0-9]+)\)} $line match p m n]} {
	    set progresscoords [list 0 [expr {1.0 * $m / $n}]]
	    adjustprogress
	}
	return 1
    }
    set progresscoords {0 0}
    adjustprogress
    notbusy checkout
    if {[catch {close $fd} err]} {
	error_popup $err
    }
    set oldmainid $mainheadid
    set mainhead $newhead
    set mainheadid $newheadid
    set viewmainheadid($curview) $newheadid
    redrawtags $oldmainid
    redrawtags $newheadid
    selbyid $newheadid
    if {$showlocalchanges} {
	dodiffindex
    }
}

proc rmbranch {} {
    global headmenuid headmenuhead mainhead
    global idheads

    set head $headmenuhead
    set id $headmenuid
    # this check shouldn't be needed any more...
    if {$head eq $mainhead} {
	error_popup [mc "Cannot delete the currently checked-out branch"]
	return
    }
    set dheads [descheads $id]
    if {[llength $dheads] == 1 && $idheads($dheads) eq $head} {
	# the stuff on this branch isn't on any other branch
	if {![confirm_popup [mc "The commits on branch %s aren't on any other\
			branch.\nReally delete branch %s?" $head $head]]} return
    }
    nowbusy rmbranch
    update
    if {[catch {exec git branch -D $head} err]} {
	notbusy rmbranch
	error_popup $err
	return
    }
    removehead $id $head
    removedhead $id $head
    redrawtags $id
    notbusy rmbranch
    dispneartags 0
    run refill_reflist
}

# Display a list of tags and heads
proc showrefs {} {
    global showrefstop bgcolor fgcolor selectbgcolor NS
    global bglist fglist reflistfilter reflist maincursor

    set top .showrefs
    set showrefstop $top
    if {[winfo exists $top]} {
	raise $top
	refill_reflist
	return
    }
    ttk_toplevel $top
    wm title $top [mc "Tags and heads: %s" [file tail [pwd]]]
    make_transient $top .
    text $top.list -background $bgcolor -foreground $fgcolor \
	-selectbackground $selectbgcolor -font mainfont \
	-xscrollcommand "$top.xsb set" -yscrollcommand "$top.ysb set" \
	-width 30 -height 20 -cursor $maincursor \
	-spacing1 1 -spacing3 1 -state disabled
    $top.list tag configure highlight -background $selectbgcolor
    lappend bglist $top.list
    lappend fglist $top.list
    ${NS}::scrollbar $top.ysb -command "$top.list yview" -orient vertical
    ${NS}::scrollbar $top.xsb -command "$top.list xview" -orient horizontal
    grid $top.list $top.ysb -sticky nsew
    grid $top.xsb x -sticky ew
    ${NS}::frame $top.f
    ${NS}::label $top.f.l -text "[mc "Filter"]: "
    ${NS}::entry $top.f.e -width 20 -textvariable reflistfilter
    set reflistfilter "*"
    trace add variable reflistfilter write reflistfilter_change
    pack $top.f.e -side right -fill x -expand 1
    pack $top.f.l -side left
    grid $top.f - -sticky ew -pady 2
    ${NS}::button $top.close -command [list destroy $top] -text [mc "Close"]
    bind $top <Key-Escape> [list destroy $top]
    grid $top.close -
    grid columnconfigure $top 0 -weight 1
    grid rowconfigure $top 0 -weight 1
    bind $top.list <1> {break}
    bind $top.list <B1-Motion> {break}
    bind $top.list <ButtonRelease-1> {sel_reflist %W %x %y; break}
    set reflist {}
    refill_reflist
}

proc sel_reflist {w x y} {
    global showrefstop reflist headids tagids otherrefids

    if {![winfo exists $showrefstop]} return
    set l [lindex [split [$w index "@$x,$y"] "."] 0]
    set ref [lindex $reflist [expr {$l-1}]]
    set n [lindex $ref 0]
    switch -- [lindex $ref 1] {
	"H" {selbyid $headids($n)}
	"T" {selbyid $tagids($n)}
	"o" {selbyid $otherrefids($n)}
    }
    $showrefstop.list tag add highlight $l.0 "$l.0 lineend"
}

proc unsel_reflist {} {
    global showrefstop

    if {![info exists showrefstop] || ![winfo exists $showrefstop]} return
    $showrefstop.list tag remove highlight 0.0 end
}

proc reflistfilter_change {n1 n2 op} {
    global reflistfilter

    after cancel refill_reflist
    after 200 refill_reflist
}

proc refill_reflist {} {
    global reflist reflistfilter showrefstop headids tagids otherrefids
    global curview

    if {![info exists showrefstop] || ![winfo exists $showrefstop]} return
    set refs {}
    foreach n [array names headids] {
	if {[string match $reflistfilter $n]} {
	    if {[commitinview $headids($n) $curview]} {
		lappend refs [list $n H]
	    } else {
		interestedin $headids($n) {run refill_reflist}
	    }
	}
    }
    foreach n [array names tagids] {
	if {[string match $reflistfilter $n]} {
	    if {[commitinview $tagids($n) $curview]} {
		lappend refs [list $n T]
	    } else {
		interestedin $tagids($n) {run refill_reflist}
	    }
	}
    }
    foreach n [array names otherrefids] {
	if {[string match $reflistfilter $n]} {
	    if {[commitinview $otherrefids($n) $curview]} {
		lappend refs [list $n o]
	    } else {
		interestedin $otherrefids($n) {run refill_reflist}
	    }
	}
    }
    set refs [lsort -index 0 $refs]
    if {$refs eq $reflist} return

    # Update the contents of $showrefstop.list according to the
    # differences between $reflist (old) and $refs (new)
    $showrefstop.list conf -state normal
    $showrefstop.list insert end "\n"
    set i 0
    set j 0
    while {$i < [llength $reflist] || $j < [llength $refs]} {
	if {$i < [llength $reflist]} {
	    if {$j < [llength $refs]} {
		set cmp [string compare [lindex $reflist $i 0] \
			     [lindex $refs $j 0]]
		if {$cmp == 0} {
		    set cmp [string compare [lindex $reflist $i 1] \
				 [lindex $refs $j 1]]
		}
	    } else {
		set cmp -1
	    }
	} else {
	    set cmp 1
	}
	switch -- $cmp {
	    -1 {
		$showrefstop.list delete "[expr {$j+1}].0" "[expr {$j+2}].0"
		incr i
	    }
	    0 {
		incr i
		incr j
	    }
	    1 {
		set l [expr {$j + 1}]
		$showrefstop.list image create $l.0 -align baseline \
		    -image reficon-[lindex $refs $j 1] -padx 2
		$showrefstop.list insert $l.1 "[lindex $refs $j 0]\n"
		incr j
	    }
	}
    }
    set reflist $refs
    # delete last newline
    $showrefstop.list delete end-2c end-1c
    $showrefstop.list conf -state disabled
}

# Stuff for finding nearby tags
proc getallcommits {} {
    global allcommits nextarc seeds allccache allcwait cachedarcs allcupdate
    global idheads idtags idotherrefs allparents tagobjid
    global gitdir

    if {![info exists allcommits]} {
	set nextarc 0
	set allcommits 0
	set seeds {}
	set allcwait 0
	set cachedarcs 0
	set allccache [file join $gitdir "gitk.cache"]
	if {![catch {
	    set f [open $allccache r]
	    set allcwait 1
	    getcache $f
	}]} return
    }

    if {$allcwait} {
	return
    }
    set cmd [list | git rev-list --parents]
    set allcupdate [expr {$seeds ne {}}]
    if {!$allcupdate} {
	set ids "--all"
    } else {
	set refs [concat [array names idheads] [array names idtags] \
		      [array names idotherrefs]]
	set ids {}
	set tagobjs {}
	foreach name [array names tagobjid] {
	    lappend tagobjs $tagobjid($name)
	}
	foreach id [lsort -unique $refs] {
	    if {![info exists allparents($id)] &&
		[lsearch -exact $tagobjs $id] < 0} {
		lappend ids $id
	    }
	}
	if {$ids ne {}} {
	    foreach id $seeds {
		lappend ids "^$id"
	    }
	}
    }
    if {$ids ne {}} {
	set fd [open [concat $cmd $ids] r]
	fconfigure $fd -blocking 0
	incr allcommits
	nowbusy allcommits
	filerun $fd [list getallclines $fd]
    } else {
	dispneartags 0
    }
}

# Since most commits have 1 parent and 1 child, we group strings of
# such commits into "arcs" joining branch/merge points (BMPs), which
# are commits that either don't have 1 parent or don't have 1 child.
#
# arcnos(id) - incoming arcs for BMP, arc we're on for other nodes
# arcout(id) - outgoing arcs for BMP
# arcids(a) - list of IDs on arc including end but not start
# arcstart(a) - BMP ID at start of arc
# arcend(a) - BMP ID at end of arc
# growing(a) - arc a is still growing
# arctags(a) - IDs out of arcids (excluding end) that have tags
# archeads(a) - IDs out of arcids (excluding end) that have heads
# The start of an arc is at the descendent end, so "incoming" means
# coming from descendents, and "outgoing" means going towards ancestors.

proc getallclines {fd} {
    global allparents allchildren idtags idheads nextarc
    global arcnos arcids arctags arcout arcend arcstart archeads growing
    global seeds allcommits cachedarcs allcupdate

    set nid 0
    while {[incr nid] <= 1000 && [gets $fd line] >= 0} {
	set id [lindex $line 0]
	if {[info exists allparents($id)]} {
	    # seen it already
	    continue
	}
	set cachedarcs 0
	set olds [lrange $line 1 end]
	set allparents($id) $olds
	if {![info exists allchildren($id)]} {
	    set allchildren($id) {}
	    set arcnos($id) {}
	    lappend seeds $id
	} else {
	    set a $arcnos($id)
	    if {[llength $olds] == 1 && [llength $a] == 1} {
		lappend arcids($a) $id
		if {[info exists idtags($id)]} {
		    lappend arctags($a) $id
		}
		if {[info exists idheads($id)]} {
		    lappend archeads($a) $id
		}
		if {[info exists allparents($olds)]} {
		    # seen parent already
		    if {![info exists arcout($olds)]} {
			splitarc $olds
		    }
		    lappend arcids($a) $olds
		    set arcend($a) $olds
		    unset growing($a)
		}
		lappend allchildren($olds) $id
		lappend arcnos($olds) $a
		continue
	    }
	}
	foreach a $arcnos($id) {
	    lappend arcids($a) $id
	    set arcend($a) $id
	    unset growing($a)
	}

	set ao {}
	foreach p $olds {
	    lappend allchildren($p) $id
	    set a [incr nextarc]
	    set arcstart($a) $id
	    set archeads($a) {}
	    set arctags($a) {}
	    set archeads($a) {}
	    set arcids($a) {}
	    lappend ao $a
	    set growing($a) 1
	    if {[info exists allparents($p)]} {
		# seen it already, may need to make a new branch
		if {![info exists arcout($p)]} {
		    splitarc $p
		}
		lappend arcids($a) $p
		set arcend($a) $p
		unset growing($a)
	    }
	    lappend arcnos($p) $a
	}
	set arcout($id) $ao
    }
    if {$nid > 0} {
	global cached_dheads cached_dtags cached_atags
	catch {unset cached_dheads}
	catch {unset cached_dtags}
	catch {unset cached_atags}
    }
    if {![eof $fd]} {
	return [expr {$nid >= 1000? 2: 1}]
    }
    set cacheok 1
    if {[catch {
	fconfigure $fd -blocking 1
	close $fd
    } err]} {
	# got an error reading the list of commits
	# if we were updating, try rereading the whole thing again
	if {$allcupdate} {
	    incr allcommits -1
	    dropcache $err
	    return
	}
	error_popup "[mc "Error reading commit topology information;\
		branch and preceding/following tag information\
	        will be incomplete."]\n($err)"
	set cacheok 0
    }
    if {[incr allcommits -1] == 0} {
	notbusy allcommits
	if {$cacheok} {
	    run savecache
	}
    }
    dispneartags 0
    return 0
}

proc recalcarc {a} {
    global arctags archeads arcids idtags idheads

    set at {}
    set ah {}
    foreach id [lrange $arcids($a) 0 end-1] {
	if {[info exists idtags($id)]} {
	    lappend at $id
	}
	if {[info exists idheads($id)]} {
	    lappend ah $id
	}
    }
    set arctags($a) $at
    set archeads($a) $ah
}

proc splitarc {p} {
    global arcnos arcids nextarc arctags archeads idtags idheads
    global arcstart arcend arcout allparents growing

    set a $arcnos($p)
    if {[llength $a] != 1} {
	puts "oops splitarc called but [llength $a] arcs already"
	return
    }
    set a [lindex $a 0]
    set i [lsearch -exact $arcids($a) $p]
    if {$i < 0} {
	puts "oops splitarc $p not in arc $a"
	return
    }
    set na [incr nextarc]
    if {[info exists arcend($a)]} {
	set arcend($na) $arcend($a)
    } else {
	set l [lindex $allparents([lindex $arcids($a) end]) 0]
	set j [lsearch -exact $arcnos($l) $a]
	set arcnos($l) [lreplace $arcnos($l) $j $j $na]
    }
    set tail [lrange $arcids($a) [expr {$i+1}] end]
    set arcids($a) [lrange $arcids($a) 0 $i]
    set arcend($a) $p
    set arcstart($na) $p
    set arcout($p) $na
    set arcids($na) $tail
    if {[info exists growing($a)]} {
	set growing($na) 1
	unset growing($a)
    }

    foreach id $tail {
	if {[llength $arcnos($id)] == 1} {
	    set arcnos($id) $na
	} else {
	    set j [lsearch -exact $arcnos($id) $a]
	    set arcnos($id) [lreplace $arcnos($id) $j $j $na]
	}
    }

    # reconstruct tags and heads lists
    if {$arctags($a) ne {} || $archeads($a) ne {}} {
	recalcarc $a
	recalcarc $na
    } else {
	set arctags($na) {}
	set archeads($na) {}
    }
}

# Update things for a new commit added that is a child of one
# existing commit.  Used when cherry-picking.
proc addnewchild {id p} {
    global allparents allchildren idtags nextarc
    global arcnos arcids arctags arcout arcend arcstart archeads growing
    global seeds allcommits

    if {![info exists allcommits] || ![info exists arcnos($p)]} return
    set allparents($id) [list $p]
    set allchildren($id) {}
    set arcnos($id) {}
    lappend seeds $id
    lappend allchildren($p) $id
    set a [incr nextarc]
    set arcstart($a) $id
    set archeads($a) {}
    set arctags($a) {}
    set arcids($a) [list $p]
    set arcend($a) $p
    if {![info exists arcout($p)]} {
	splitarc $p
    }
    lappend arcnos($p) $a
    set arcout($id) [list $a]
}

# This implements a cache for the topology information.
# The cache saves, for each arc, the start and end of the arc,
# the ids on the arc, and the outgoing arcs from the end.
proc readcache {f} {
    global arcnos arcids arcout arcstart arcend arctags archeads nextarc
    global idtags idheads allparents cachedarcs possible_seeds seeds growing
    global allcwait

    set a $nextarc
    set lim $cachedarcs
    if {$lim - $a > 500} {
	set lim [expr {$a + 500}]
    }
    if {[catch {
	if {$a == $lim} {
	    # finish reading the cache and setting up arctags, etc.
	    set line [gets $f]
	    if {$line ne "1"} {error "bad final version"}
	    close $f
	    foreach id [array names idtags] {
		if {[info exists arcnos($id)] && [llength $arcnos($id)] == 1 &&
		    [llength $allparents($id)] == 1} {
		    set a [lindex $arcnos($id) 0]
		    if {$arctags($a) eq {}} {
			recalcarc $a
		    }
		}
	    }
	    foreach id [array names idheads] {
		if {[info exists arcnos($id)] && [llength $arcnos($id)] == 1 &&
		    [llength $allparents($id)] == 1} {
		    set a [lindex $arcnos($id) 0]
		    if {$archeads($a) eq {}} {
			recalcarc $a
		    }
		}
	    }
	    foreach id [lsort -unique $possible_seeds] {
		if {$arcnos($id) eq {}} {
		    lappend seeds $id
		}
	    }
	    set allcwait 0
	} else {
	    while {[incr a] <= $lim} {
		set line [gets $f]
		if {[llength $line] != 3} {error "bad line"}
		set s [lindex $line 0]
		set arcstart($a) $s
		lappend arcout($s) $a
		if {![info exists arcnos($s)]} {
		    lappend possible_seeds $s
		    set arcnos($s) {}
		}
		set e [lindex $line 1]
		if {$e eq {}} {
		    set growing($a) 1
		} else {
		    set arcend($a) $e
		    if {![info exists arcout($e)]} {
			set arcout($e) {}
		    }
		}
		set arcids($a) [lindex $line 2]
		foreach id $arcids($a) {
		    lappend allparents($s) $id
		    set s $id
		    lappend arcnos($id) $a
		}
		if {![info exists allparents($s)]} {
		    set allparents($s) {}
		}
		set arctags($a) {}
		set archeads($a) {}
	    }
	    set nextarc [expr {$a - 1}]
	}
    } err]} {
	dropcache $err
	return 0
    }
    if {!$allcwait} {
	getallcommits
    }
    return $allcwait
}

proc getcache {f} {
    global nextarc cachedarcs possible_seeds

    if {[catch {
	set line [gets $f]
	if {[llength $line] != 2 || [lindex $line 0] ne "1"} {error "bad version"}
	# make sure it's an integer
	set cachedarcs [expr {int([lindex $line 1])}]
	if {$cachedarcs < 0} {error "bad number of arcs"}
	set nextarc 0
	set possible_seeds {}
	run readcache $f
    } err]} {
	dropcache $err
    }
    return 0
}

proc dropcache {err} {
    global allcwait nextarc cachedarcs seeds

    #puts "dropping cache ($err)"
    foreach v {arcnos arcout arcids arcstart arcend growing \
		   arctags archeads allparents allchildren} {
	global $v
	catch {unset $v}
    }
    set allcwait 0
    set nextarc 0
    set cachedarcs 0
    set seeds {}
    getallcommits
}

proc writecache {f} {
    global cachearc cachedarcs allccache
    global arcstart arcend arcnos arcids arcout

    set a $cachearc
    set lim $cachedarcs
    if {$lim - $a > 1000} {
	set lim [expr {$a + 1000}]
    }
    if {[catch {
	while {[incr a] <= $lim} {
	    if {[info exists arcend($a)]} {
		puts $f [list $arcstart($a) $arcend($a) $arcids($a)]
	    } else {
		puts $f [list $arcstart($a) {} $arcids($a)]
	    }
	}
    } err]} {
	catch {close $f}
	catch {file delete $allccache}
	#puts "writing cache failed ($err)"
	return 0
    }
    set cachearc [expr {$a - 1}]
    if {$a > $cachedarcs} {
	puts $f "1"
	close $f
	return 0
    }
    return 1
}

proc savecache {} {
    global nextarc cachedarcs cachearc allccache

    if {$nextarc == $cachedarcs} return
    set cachearc 0
    set cachedarcs $nextarc
    catch {
	set f [open $allccache w]
	puts $f [list 1 $cachedarcs]
	run writecache $f
    }
}

# Returns 1 if a is an ancestor of b, -1 if b is an ancestor of a,
# or 0 if neither is true.
proc anc_or_desc {a b} {
    global arcout arcstart arcend arcnos cached_isanc

    if {$arcnos($a) eq $arcnos($b)} {
	# Both are on the same arc(s); either both are the same BMP,
	# or if one is not a BMP, the other is also not a BMP or is
	# the BMP at end of the arc (and it only has 1 incoming arc).
	# Or both can be BMPs with no incoming arcs.
	if {$a eq $b || $arcnos($a) eq {}} {
	    return 0
	}
	# assert {[llength $arcnos($a)] == 1}
	set arc [lindex $arcnos($a) 0]
	set i [lsearch -exact $arcids($arc) $a]
	set j [lsearch -exact $arcids($arc) $b]
	if {$i < 0 || $i > $j} {
	    return 1
	} else {
	    return -1
	}
    }

    if {![info exists arcout($a)]} {
	set arc [lindex $arcnos($a) 0]
	if {[info exists arcend($arc)]} {
	    set aend $arcend($arc)
	} else {
	    set aend {}
	}
	set a $arcstart($arc)
    } else {
	set aend $a
    }
    if {![info exists arcout($b)]} {
	set arc [lindex $arcnos($b) 0]
	if {[info exists arcend($arc)]} {
	    set bend $arcend($arc)
	} else {
	    set bend {}
	}
	set b $arcstart($arc)
    } else {
	set bend $b
    }
    if {$a eq $bend} {
	return 1
    }
    if {$b eq $aend} {
	return -1
    }
    if {[info exists cached_isanc($a,$bend)]} {
	if {$cached_isanc($a,$bend)} {
	    return 1
	}
    }
    if {[info exists cached_isanc($b,$aend)]} {
	if {$cached_isanc($b,$aend)} {
	    return -1
	}
	if {[info exists cached_isanc($a,$bend)]} {
	    return 0
	}
    }

    set todo [list $a $b]
    set anc($a) a
    set anc($b) b
    for {set i 0} {$i < [llength $todo]} {incr i} {
	set x [lindex $todo $i]
	if {$anc($x) eq {}} {
	    continue
	}
	foreach arc $arcnos($x) {
	    set xd $arcstart($arc)
	    if {$xd eq $bend} {
		set cached_isanc($a,$bend) 1
		set cached_isanc($b,$aend) 0
		return 1
	    } elseif {$xd eq $aend} {
		set cached_isanc($b,$aend) 1
		set cached_isanc($a,$bend) 0
		return -1
	    }
	    if {![info exists anc($xd)]} {
		set anc($xd) $anc($x)
		lappend todo $xd
	    } elseif {$anc($xd) ne $anc($x)} {
		set anc($xd) {}
	    }
	}
    }
    set cached_isanc($a,$bend) 0
    set cached_isanc($b,$aend) 0
    return 0
}

# This identifies whether $desc has an ancestor that is
# a growing tip of the graph and which is not an ancestor of $anc
# and returns 0 if so and 1 if not.
# If we subsequently discover a tag on such a growing tip, and that
# turns out to be a descendent of $anc (which it could, since we
# don't necessarily see children before parents), then $desc
# isn't a good choice to display as a descendent tag of
# $anc (since it is the descendent of another tag which is
# a descendent of $anc).  Similarly, $anc isn't a good choice to
# display as a ancestor tag of $desc.
#
proc is_certain {desc anc} {
    global arcnos arcout arcstart arcend growing problems

    set certain {}
    if {[llength $arcnos($anc)] == 1} {
	# tags on the same arc are certain
	if {$arcnos($desc) eq $arcnos($anc)} {
	    return 1
	}
	if {![info exists arcout($anc)]} {
	    # if $anc is partway along an arc, use the start of the arc instead
	    set a [lindex $arcnos($anc) 0]
	    set anc $arcstart($a)
	}
    }
    if {[llength $arcnos($desc)] > 1 || [info exists arcout($desc)]} {
	set x $desc
    } else {
	set a [lindex $arcnos($desc) 0]
	set x $arcend($a)
    }
    if {$x == $anc} {
	return 1
    }
    set anclist [list $x]
    set dl($x) 1
    set nnh 1
    set ngrowanc 0
    for {set i 0} {$i < [llength $anclist] && ($nnh > 0 || $ngrowanc > 0)} {incr i} {
	set x [lindex $anclist $i]
	if {$dl($x)} {
	    incr nnh -1
	}
	set done($x) 1
	foreach a $arcout($x) {
	    if {[info exists growing($a)]} {
		if {![info exists growanc($x)] && $dl($x)} {
		    set growanc($x) 1
		    incr ngrowanc
		}
	    } else {
		set y $arcend($a)
		if {[info exists dl($y)]} {
		    if {$dl($y)} {
			if {!$dl($x)} {
			    set dl($y) 0
			    if {![info exists done($y)]} {
				incr nnh -1
			    }
			    if {[info exists growanc($x)]} {
				incr ngrowanc -1
			    }
			    set xl [list $y]
			    for {set k 0} {$k < [llength $xl]} {incr k} {
				set z [lindex $xl $k]
				foreach c $arcout($z) {
				    if {[info exists arcend($c)]} {
					set v $arcend($c)
					if {[info exists dl($v)] && $dl($v)} {
					    set dl($v) 0
					    if {![info exists done($v)]} {
						incr nnh -1
					    }
					    if {[info exists growanc($v)]} {
						incr ngrowanc -1
					    }
					    lappend xl $v
					}
				    }
				}
			    }
			}
		    }
		} elseif {$y eq $anc || !$dl($x)} {
		    set dl($y) 0
		    lappend anclist $y
		} else {
		    set dl($y) 1
		    lappend anclist $y
		    incr nnh
		}
	    }
	}
    }
    foreach x [array names growanc] {
	if {$dl($x)} {
	    return 0
	}
	return 0
    }
    return 1
}

proc validate_arctags {a} {
    global arctags idtags

    set i -1
    set na $arctags($a)
    foreach id $arctags($a) {
	incr i
	if {![info exists idtags($id)]} {
	    set na [lreplace $na $i $i]
	    incr i -1
	}
    }
    set arctags($a) $na
}

proc validate_archeads {a} {
    global archeads idheads

    set i -1
    set na $archeads($a)
    foreach id $archeads($a) {
	incr i
	if {![info exists idheads($id)]} {
	    set na [lreplace $na $i $i]
	    incr i -1
	}
    }
    set archeads($a) $na
}

# Return the list of IDs that have tags that are descendents of id,
# ignoring IDs that are descendents of IDs already reported.
proc desctags {id} {
    global arcnos arcstart arcids arctags idtags allparents
    global growing cached_dtags

    if {![info exists allparents($id)]} {
	return {}
    }
    set t1 [clock clicks -milliseconds]
    set argid $id
    if {[llength $arcnos($id)] == 1 && [llength $allparents($id)] == 1} {
	# part-way along an arc; check that arc first
	set a [lindex $arcnos($id) 0]
	if {$arctags($a) ne {}} {
	    validate_arctags $a
	    set i [lsearch -exact $arcids($a) $id]
	    set tid {}
	    foreach t $arctags($a) {
		set j [lsearch -exact $arcids($a) $t]
		if {$j >= $i} break
		set tid $t
	    }
	    if {$tid ne {}} {
		return $tid
	    }
	}
	set id $arcstart($a)
	if {[info exists idtags($id)]} {
	    return $id
	}
    }
    if {[info exists cached_dtags($id)]} {
	return $cached_dtags($id)
    }

    set origid $id
    set todo [list $id]
    set queued($id) 1
    set nc 1
    for {set i 0} {$i < [llength $todo] && $nc > 0} {incr i} {
	set id [lindex $todo $i]
	set done($id) 1
	set ta [info exists hastaggedancestor($id)]
	if {!$ta} {
	    incr nc -1
	}
	# ignore tags on starting node
	if {!$ta && $i > 0} {
	    if {[info exists idtags($id)]} {
		set tagloc($id) $id
		set ta 1
	    } elseif {[info exists cached_dtags($id)]} {
		set tagloc($id) $cached_dtags($id)
		set ta 1
	    }
	}
	foreach a $arcnos($id) {
	    set d $arcstart($a)
	    if {!$ta && $arctags($a) ne {}} {
		validate_arctags $a
		if {$arctags($a) ne {}} {
		    lappend tagloc($id) [lindex $arctags($a) end]
		}
	    }
	    if {$ta || $arctags($a) ne {}} {
		set tomark [list $d]
		for {set j 0} {$j < [llength $tomark]} {incr j} {
		    set dd [lindex $tomark $j]
		    if {![info exists hastaggedancestor($dd)]} {
			if {[info exists done($dd)]} {
			    foreach b $arcnos($dd) {
				lappend tomark $arcstart($b)
			    }
			    if {[info exists tagloc($dd)]} {
				unset tagloc($dd)
			    }
			} elseif {[info exists queued($dd)]} {
			    incr nc -1
			}
			set hastaggedancestor($dd) 1
		    }
		}
	    }
	    if {![info exists queued($d)]} {
		lappend todo $d
		set queued($d) 1
		if {![info exists hastaggedancestor($d)]} {
		    incr nc
		}
	    }
	}
    }
    set tags {}
    foreach id [array names tagloc] {
	if {![info exists hastaggedancestor($id)]} {
	    foreach t $tagloc($id) {
		if {[lsearch -exact $tags $t] < 0} {
		    lappend tags $t
		}
	    }
	}
    }
    set t2 [clock clicks -milliseconds]
    set loopix $i

    # remove tags that are descendents of other tags
    for {set i 0} {$i < [llength $tags]} {incr i} {
	set a [lindex $tags $i]
	for {set j 0} {$j < $i} {incr j} {
	    set b [lindex $tags $j]
	    set r [anc_or_desc $a $b]
	    if {$r == 1} {
		set tags [lreplace $tags $j $j]
		incr j -1
		incr i -1
	    } elseif {$r == -1} {
		set tags [lreplace $tags $i $i]
		incr i -1
		break
	    }
	}
    }

    if {[array names growing] ne {}} {
	# graph isn't finished, need to check if any tag could get
	# eclipsed by another tag coming later.  Simply ignore any
	# tags that could later get eclipsed.
	set ctags {}
	foreach t $tags {
	    if {[is_certain $t $origid]} {
		lappend ctags $t
	    }
	}
	if {$tags eq $ctags} {
	    set cached_dtags($origid) $tags
	} else {
	    set tags $ctags
	}
    } else {
	set cached_dtags($origid) $tags
    }
    set t3 [clock clicks -milliseconds]
    if {0 && $t3 - $t1 >= 100} {
	puts "iterating descendents ($loopix/[llength $todo] nodes) took\
    	    [expr {$t2-$t1}]+[expr {$t3-$t2}]ms, $nc candidates left"
    }
    return $tags
}

proc anctags {id} {
    global arcnos arcids arcout arcend arctags idtags allparents
    global growing cached_atags

    if {![info exists allparents($id)]} {
	return {}
    }
    set t1 [clock clicks -milliseconds]
    set argid $id
    if {[llength $arcnos($id)] == 1 && [llength $allparents($id)] == 1} {
	# part-way along an arc; check that arc first
	set a [lindex $arcnos($id) 0]
	if {$arctags($a) ne {}} {
	    validate_arctags $a
	    set i [lsearch -exact $arcids($a) $id]
	    foreach t $arctags($a) {
		set j [lsearch -exact $arcids($a) $t]
		if {$j > $i} {
		    return $t
		}
	    }
	}
	if {![info exists arcend($a)]} {
	    return {}
	}
	set id $arcend($a)
	if {[info exists idtags($id)]} {
	    return $id
	}
    }
    if {[info exists cached_atags($id)]} {
	return $cached_atags($id)
    }

    set origid $id
    set todo [list $id]
    set queued($id) 1
    set taglist {}
    set nc 1
    for {set i 0} {$i < [llength $todo] && $nc > 0} {incr i} {
	set id [lindex $todo $i]
	set done($id) 1
	set td [info exists hastaggeddescendent($id)]
	if {!$td} {
	    incr nc -1
	}
	# ignore tags on starting node
	if {!$td && $i > 0} {
	    if {[info exists idtags($id)]} {
		set tagloc($id) $id
		set td 1
	    } elseif {[info exists cached_atags($id)]} {
		set tagloc($id) $cached_atags($id)
		set td 1
	    }
	}
	foreach a $arcout($id) {
	    if {!$td && $arctags($a) ne {}} {
		validate_arctags $a
		if {$arctags($a) ne {}} {
		    lappend tagloc($id) [lindex $arctags($a) 0]
		}
	    }
	    if {![info exists arcend($a)]} continue
	    set d $arcend($a)
	    if {$td || $arctags($a) ne {}} {
		set tomark [list $d]
		for {set j 0} {$j < [llength $tomark]} {incr j} {
		    set dd [lindex $tomark $j]
		    if {![info exists hastaggeddescendent($dd)]} {
			if {[info exists done($dd)]} {
			    foreach b $arcout($dd) {
				if {[info exists arcend($b)]} {
				    lappend tomark $arcend($b)
				}
			    }
			    if {[info exists tagloc($dd)]} {
				unset tagloc($dd)
			    }
			} elseif {[info exists queued($dd)]} {
			    incr nc -1
			}
			set hastaggeddescendent($dd) 1
		    }
		}
	    }
	    if {![info exists queued($d)]} {
		lappend todo $d
		set queued($d) 1
		if {![info exists hastaggeddescendent($d)]} {
		    incr nc
		}
	    }
	}
    }
    set t2 [clock clicks -milliseconds]
    set loopix $i
    set tags {}
    foreach id [array names tagloc] {
	if {![info exists hastaggeddescendent($id)]} {
	    foreach t $tagloc($id) {
		if {[lsearch -exact $tags $t] < 0} {
		    lappend tags $t
		}
	    }
	}
    }

    # remove tags that are ancestors of other tags
    for {set i 0} {$i < [llength $tags]} {incr i} {
	set a [lindex $tags $i]
	for {set j 0} {$j < $i} {incr j} {
	    set b [lindex $tags $j]
	    set r [anc_or_desc $a $b]
	    if {$r == -1} {
		set tags [lreplace $tags $j $j]
		incr j -1
		incr i -1
	    } elseif {$r == 1} {
		set tags [lreplace $tags $i $i]
		incr i -1
		break
	    }
	}
    }

    if {[array names growing] ne {}} {
	# graph isn't finished, need to check if any tag could get
	# eclipsed by another tag coming later.  Simply ignore any
	# tags that could later get eclipsed.
	set ctags {}
	foreach t $tags {
	    if {[is_certain $origid $t]} {
		lappend ctags $t
	    }
	}
	if {$tags eq $ctags} {
	    set cached_atags($origid) $tags
	} else {
	    set tags $ctags
	}
    } else {
	set cached_atags($origid) $tags
    }
    set t3 [clock clicks -milliseconds]
    if {0 && $t3 - $t1 >= 100} {
	puts "iterating ancestors ($loopix/[llength $todo] nodes) took\
    	    [expr {$t2-$t1}]+[expr {$t3-$t2}]ms, $nc candidates left"
    }
    return $tags
}

# Return the list of IDs that have heads that are descendents of id,
# including id itself if it has a head.
proc descheads {id} {
    global arcnos arcstart arcids archeads idheads cached_dheads
    global allparents arcout

    if {![info exists allparents($id)]} {
	return {}
    }
    set aret {}
    if {![info exists arcout($id)]} {
	# part-way along an arc; check it first
	set a [lindex $arcnos($id) 0]
	if {$archeads($a) ne {}} {
	    validate_archeads $a
	    set i [lsearch -exact $arcids($a) $id]
	    foreach t $archeads($a) {
		set j [lsearch -exact $arcids($a) $t]
		if {$j > $i} break
		lappend aret $t
	    }
	}
	set id $arcstart($a)
    }
    set origid $id
    set todo [list $id]
    set seen($id) 1
    set ret {}
    for {set i 0} {$i < [llength $todo]} {incr i} {
	set id [lindex $todo $i]
	if {[info exists cached_dheads($id)]} {
	    set ret [concat $ret $cached_dheads($id)]
	} else {
	    if {[info exists idheads($id)]} {
		lappend ret $id
	    }
	    foreach a $arcnos($id) {
		if {$archeads($a) ne {}} {
		    validate_archeads $a
		    if {$archeads($a) ne {}} {
			set ret [concat $ret $archeads($a)]
		    }
		}
		set d $arcstart($a)
		if {![info exists seen($d)]} {
		    lappend todo $d
		    set seen($d) 1
		}
	    }
	}
    }
    set ret [lsort -unique $ret]
    set cached_dheads($origid) $ret
    return [concat $ret $aret]
}

proc addedtag {id} {
    global arcnos arcout cached_dtags cached_atags

    if {![info exists arcnos($id)]} return
    if {![info exists arcout($id)]} {
	recalcarc [lindex $arcnos($id) 0]
    }
    catch {unset cached_dtags}
    catch {unset cached_atags}
}

proc addedhead {hid head} {
    global arcnos arcout cached_dheads

    if {![info exists arcnos($hid)]} return
    if {![info exists arcout($hid)]} {
	recalcarc [lindex $arcnos($hid) 0]
    }
    catch {unset cached_dheads}
}

proc removedhead {hid head} {
    global cached_dheads

    catch {unset cached_dheads}
}

proc movedhead {hid head} {
    global arcnos arcout cached_dheads

    if {![info exists arcnos($hid)]} return
    if {![info exists arcout($hid)]} {
	recalcarc [lindex $arcnos($hid) 0]
    }
    catch {unset cached_dheads}
}

proc changedrefs {} {
    global cached_dheads cached_dtags cached_atags cached_tagcontent
    global arctags archeads arcnos arcout idheads idtags

    foreach id [concat [array names idheads] [array names idtags]] {
	if {[info exists arcnos($id)] && ![info exists arcout($id)]} {
	    set a [lindex $arcnos($id) 0]
	    if {![info exists donearc($a)]} {
		recalcarc $a
		set donearc($a) 1
	    }
	}
    }
    catch {unset cached_tagcontent}
    catch {unset cached_dtags}
    catch {unset cached_atags}
    catch {unset cached_dheads}
}

proc rereadrefs {} {
    global idtags idheads idotherrefs mainheadid

    set refids [concat [array names idtags] \
		    [array names idheads] [array names idotherrefs]]
    foreach id $refids {
	if {![info exists ref($id)]} {
	    set ref($id) [listrefs $id]
	}
    }
    set oldmainhead $mainheadid
    readrefs
    changedrefs
    set refids [lsort -unique [concat $refids [array names idtags] \
			[array names idheads] [array names idotherrefs]]]
    foreach id $refids {
	set v [listrefs $id]
	if {![info exists ref($id)] || $ref($id) != $v} {
	    redrawtags $id
	}
    }
    if {$oldmainhead ne $mainheadid} {
	redrawtags $oldmainhead
	redrawtags $mainheadid
    }
    run refill_reflist
}

proc listrefs {id} {
    global idtags idheads idotherrefs

    set x {}
    if {[info exists idtags($id)]} {
	set x $idtags($id)
    }
    set y {}
    if {[info exists idheads($id)]} {
	set y $idheads($id)
    }
    set z {}
    if {[info exists idotherrefs($id)]} {
	set z $idotherrefs($id)
    }
    return [list $x $y $z]
}

proc add_tag_ctext {tag} {
    global ctext cached_tagcontent tagids

    if {![info exists cached_tagcontent($tag)]} {
	catch {
	    set cached_tagcontent($tag) [exec git cat-file -p $tag]
	}
    }
    $ctext insert end "[mc "Tag"]: $tag\n" bold
    if {[info exists cached_tagcontent($tag)]} {
	set text $cached_tagcontent($tag)
    } else {
	set text "[mc "Id"]:  $tagids($tag)"
    }
    appendwithlinks $text {}
}

proc showtag {tag isnew} {
    global ctext cached_tagcontent tagids linknum tagobjid

    if {$isnew} {
	addtohistory [list showtag $tag 0] savectextpos
    }
    $ctext conf -state normal
    clear_ctext
    settabs 0
    set linknum 0
    add_tag_ctext $tag
    maybe_scroll_ctext 1
    $ctext conf -state disabled
    init_flist {}
}

proc showtags {id isnew} {
    global idtags ctext linknum

    if {$isnew} {
	addtohistory [list showtags $id 0] savectextpos
    }
    $ctext conf -state normal
    clear_ctext
    settabs 0
    set linknum 0
    set sep {}
    foreach tag $idtags($id) {
	$ctext insert end $sep
	add_tag_ctext $tag
	set sep "\n\n"
    }
    maybe_scroll_ctext 1
    $ctext conf -state disabled
    init_flist {}
}

proc doquit {} {
    global stopped
    global gitktmpdir

    set stopped 100
    savestuff .
    destroy .

    if {[info exists gitktmpdir]} {
	catch {file delete -force $gitktmpdir}
    }
}

proc mkfontdisp {font top which} {
    global fontattr fontpref $font NS use_ttk

    set fontpref($font) [set $font]
    ${NS}::button $top.${font}but -text $which \
	-command [list choosefont $font $which]
    ${NS}::label $top.$font -relief flat -font $font \
	-text $fontattr($font,family) -justify left
    grid x $top.${font}but $top.$font -sticky w
}

proc choosefont {font which} {
    global fontparam fontlist fonttop fontattr
    global prefstop NS

    set fontparam(which) $which
    set fontparam(font) $font
    set fontparam(family) [font actual $font -family]
    set fontparam(size) $fontattr($font,size)
    set fontparam(weight) $fontattr($font,weight)
    set fontparam(slant) $fontattr($font,slant)
    set top .gitkfont
    set fonttop $top
    if {![winfo exists $top]} {
	font create sample
	eval font config sample [font actual $font]
	ttk_toplevel $top
	make_transient $top $prefstop
	wm title $top [mc "Gitk font chooser"]
	${NS}::label $top.l -textvariable fontparam(which)
	pack $top.l -side top
	set fontlist [lsort [font families]]
	${NS}::frame $top.f
	listbox $top.f.fam -listvariable fontlist \
	    -yscrollcommand [list $top.f.sb set]
	bind $top.f.fam <<ListboxSelect>> selfontfam
	${NS}::scrollbar $top.f.sb -command [list $top.f.fam yview]
	pack $top.f.sb -side right -fill y
	pack $top.f.fam -side left -fill both -expand 1
	pack $top.f -side top -fill both -expand 1
	${NS}::frame $top.g
	spinbox $top.g.size -from 4 -to 40 -width 4 \
	    -textvariable fontparam(size) \
	    -validatecommand {string is integer -strict %s}
	checkbutton $top.g.bold -padx 5 \
	    -font {{Times New Roman} 12 bold} -text [mc "B"] -indicatoron 0 \
	    -variable fontparam(weight) -onvalue bold -offvalue normal
	checkbutton $top.g.ital -padx 5 \
	    -font {{Times New Roman} 12 italic} -text [mc "I"] -indicatoron 0  \
	    -variable fontparam(slant) -onvalue italic -offvalue roman
	pack $top.g.size $top.g.bold $top.g.ital -side left
	pack $top.g -side top
	canvas $top.c -width 150 -height 50 -border 2 -relief sunk \
	    -background white
	$top.c create text 100 25 -anchor center -text $which -font sample \
	    -fill black -tags text
	bind $top.c <Configure> [list centertext $top.c]
	pack $top.c -side top -fill x
	${NS}::frame $top.buts
	${NS}::button $top.buts.ok -text [mc "OK"] -command fontok -default active
	${NS}::button $top.buts.can -text [mc "Cancel"] -command fontcan -default normal
	bind $top <Key-Return> fontok
	bind $top <Key-Escape> fontcan
	grid $top.buts.ok $top.buts.can
	grid columnconfigure $top.buts 0 -weight 1 -uniform a
	grid columnconfigure $top.buts 1 -weight 1 -uniform a
	pack $top.buts -side bottom -fill x
	trace add variable fontparam write chg_fontparam
    } else {
	raise $top
	$top.c itemconf text -text $which
    }
    set i [lsearch -exact $fontlist $fontparam(family)]
    if {$i >= 0} {
	$top.f.fam selection set $i
	$top.f.fam see $i
    }
}

proc centertext {w} {
    $w coords text [expr {[winfo width $w] / 2}] [expr {[winfo height $w] / 2}]
}

proc fontok {} {
    global fontparam fontpref prefstop

    set f $fontparam(font)
    set fontpref($f) [list $fontparam(family) $fontparam(size)]
    if {$fontparam(weight) eq "bold"} {
	lappend fontpref($f) "bold"
    }
    if {$fontparam(slant) eq "italic"} {
	lappend fontpref($f) "italic"
    }
    set w $prefstop.notebook.fonts.$f
    $w conf -text $fontparam(family) -font $fontpref($f)

    fontcan
}

proc fontcan {} {
    global fonttop fontparam

    if {[info exists fonttop]} {
	catch {destroy $fonttop}
	catch {font delete sample}
	unset fonttop
	unset fontparam
    }
}

if {[package vsatisfies [package provide Tk] 8.6]} {
    # In Tk 8.6 we have a native font chooser dialog. Overwrite the above
    # function to make use of it.
    proc choosefont {font which} {
	tk fontchooser configure -title $which -font $font \
	    -command [list on_choosefont $font $which]
	tk fontchooser show
    }
    proc on_choosefont {font which newfont} {
	global fontparam
	puts stderr "$font $newfont"
	array set f [font actual $newfont]
	set fontparam(which) $which
	set fontparam(font) $font
	set fontparam(family) $f(-family)
	set fontparam(size) $f(-size)
	set fontparam(weight) $f(-weight)
	set fontparam(slant) $f(-slant)
	fontok
    }
}

proc selfontfam {} {
    global fonttop fontparam

    set i [$fonttop.f.fam curselection]
    if {$i ne {}} {
	set fontparam(family) [$fonttop.f.fam get $i]
    }
}

proc chg_fontparam {v sub op} {
    global fontparam

    font config sample -$sub $fontparam($sub)
}

# Create a property sheet tab page
proc create_prefs_page {w} {
    global NS
    set parent [join [lrange [split $w .] 0 end-1] .]
    if {[winfo class $parent] eq "TNotebook"} {
	${NS}::frame $w
    } else {
	${NS}::labelframe $w
    }
}

proc prefspage_general {notebook} {
    global NS maxwidth maxgraphpct showneartags showlocalchanges
    global tabstop limitdiffs autoselect autosellen extdifftool perfile_attrs
    global hideremotes want_ttk have_ttk maxrefs

    set page [create_prefs_page $notebook.general]

    ${NS}::label $page.ldisp -text [mc "Commit list display options"]
    grid $page.ldisp - -sticky w -pady 10
    ${NS}::label $page.spacer -text " "
    ${NS}::label $page.maxwidthl -text [mc "Maximum graph width (lines)"]
    spinbox $page.maxwidth -from 0 -to 100 -width 4 -textvariable maxwidth
    grid $page.spacer $page.maxwidthl $page.maxwidth -sticky w
    ${NS}::label $page.maxpctl -text [mc "Maximum graph width (% of pane)"]
    spinbox $page.maxpct -from 1 -to 100 -width 4 -textvariable maxgraphpct
    grid x $page.maxpctl $page.maxpct -sticky w
    ${NS}::checkbutton $page.showlocal -text [mc "Show local changes"] \
	-variable showlocalchanges
    grid x $page.showlocal -sticky w
    ${NS}::checkbutton $page.autoselect -text [mc "Auto-select SHA1 (length)"] \
	-variable autoselect
    spinbox $page.autosellen -from 1 -to 40 -width 4 -textvariable autosellen
    grid x $page.autoselect $page.autosellen -sticky w
    ${NS}::checkbutton $page.hideremotes -text [mc "Hide remote refs"] \
	-variable hideremotes
    grid x $page.hideremotes -sticky w

    ${NS}::label $page.ddisp -text [mc "Diff display options"]
    grid $page.ddisp - -sticky w -pady 10
    ${NS}::label $page.tabstopl -text [mc "Tab spacing"]
    spinbox $page.tabstop -from 1 -to 20 -width 4 -textvariable tabstop
    grid x $page.tabstopl $page.tabstop -sticky w
    ${NS}::checkbutton $page.ntag -text [mc "Display nearby tags/heads"] \
	-variable showneartags
    grid x $page.ntag -sticky w
    ${NS}::label $page.maxrefsl -text [mc "Maximum # tags/heads to show"]
    spinbox $page.maxrefs -from 1 -to 1000 -width 4 -textvariable maxrefs
    grid x $page.maxrefsl $page.maxrefs -sticky w
    ${NS}::checkbutton $page.ldiff -text [mc "Limit diffs to listed paths"] \
	-variable limitdiffs
    grid x $page.ldiff -sticky w
    ${NS}::checkbutton $page.lattr -text [mc "Support per-file encodings"] \
	-variable perfile_attrs
    grid x $page.lattr -sticky w

    ${NS}::entry $page.extdifft -textvariable extdifftool
    ${NS}::frame $page.extdifff
    ${NS}::label $page.extdifff.l -text [mc "External diff tool" ]
    ${NS}::button $page.extdifff.b -text [mc "Choose..."] -command choose_extdiff
    pack $page.extdifff.l $page.extdifff.b -side left
    pack configure $page.extdifff.l -padx 10
    grid x $page.extdifff $page.extdifft -sticky ew

    ${NS}::label $page.lgen -text [mc "General options"]
    grid $page.lgen - -sticky w -pady 10
    ${NS}::checkbutton $page.want_ttk -variable want_ttk \
	-text [mc "Use themed widgets"]
    if {$have_ttk} {
	${NS}::label $page.ttk_note -text [mc "(change requires restart)"]
    } else {
	${NS}::label $page.ttk_note -text [mc "(currently unavailable)"]
    }
    grid x $page.want_ttk $page.ttk_note -sticky w
    return $page
}

proc prefspage_colors {notebook} {
    global NS uicolor bgcolor fgcolor ctext diffcolors selectbgcolor markbgcolor

    set page [create_prefs_page $notebook.colors]

    ${NS}::label $page.cdisp -text [mc "Colors: press to choose"]
    grid $page.cdisp - -sticky w -pady 10
    label $page.ui -padx 40 -relief sunk -background $uicolor
    ${NS}::button $page.uibut -text [mc "Interface"] \
       -command [list choosecolor uicolor {} $page.ui [mc "interface"] setui]
    grid x $page.uibut $page.ui -sticky w
    label $page.bg -padx 40 -relief sunk -background $bgcolor
    ${NS}::button $page.bgbut -text [mc "Background"] \
	-command [list choosecolor bgcolor {} $page.bg [mc "background"] setbg]
    grid x $page.bgbut $page.bg -sticky w
    label $page.fg -padx 40 -relief sunk -background $fgcolor
    ${NS}::button $page.fgbut -text [mc "Foreground"] \
	-command [list choosecolor fgcolor {} $page.fg [mc "foreground"] setfg]
    grid x $page.fgbut $page.fg -sticky w
    label $page.diffold -padx 40 -relief sunk -background [lindex $diffcolors 0]
    ${NS}::button $page.diffoldbut -text [mc "Diff: old lines"] \
	-command [list choosecolor diffcolors 0 $page.diffold [mc "diff old lines"] \
		      [list $ctext tag conf d0 -foreground]]
    grid x $page.diffoldbut $page.diffold -sticky w
    label $page.diffnew -padx 40 -relief sunk -background [lindex $diffcolors 1]
    ${NS}::button $page.diffnewbut -text [mc "Diff: new lines"] \
	-command [list choosecolor diffcolors 1 $page.diffnew [mc "diff new lines"] \
		      [list $ctext tag conf dresult -foreground]]
    grid x $page.diffnewbut $page.diffnew -sticky w
    label $page.hunksep -padx 40 -relief sunk -background [lindex $diffcolors 2]
    ${NS}::button $page.hunksepbut -text [mc "Diff: hunk header"] \
	-command [list choosecolor diffcolors 2 $page.hunksep \
		      [mc "diff hunk header"] \
		      [list $ctext tag conf hunksep -foreground]]
    grid x $page.hunksepbut $page.hunksep -sticky w
    label $page.markbgsep -padx 40 -relief sunk -background $markbgcolor
    ${NS}::button $page.markbgbut -text [mc "Marked line bg"] \
	-command [list choosecolor markbgcolor {} $page.markbgsep \
		      [mc "marked line background"] \
		      [list $ctext tag conf omark -background]]
    grid x $page.markbgbut $page.markbgsep -sticky w
    label $page.selbgsep -padx 40 -relief sunk -background $selectbgcolor
    ${NS}::button $page.selbgbut -text [mc "Select bg"] \
	-command [list choosecolor selectbgcolor {} $page.selbgsep [mc "background"] setselbg]
    grid x $page.selbgbut $page.selbgsep -sticky w
    return $page
}

proc prefspage_fonts {notebook} {
    global NS
    set page [create_prefs_page $notebook.fonts]
    ${NS}::label $page.cfont -text [mc "Fonts: press to choose"]
    grid $page.cfont - -sticky w -pady 10
    mkfontdisp mainfont $page [mc "Main font"]
    mkfontdisp textfont $page [mc "Diff display font"]
    mkfontdisp uifont $page [mc "User interface font"]
    return $page
}

proc doprefs {} {
    global maxwidth maxgraphpct use_ttk NS
    global oldprefs prefstop showneartags showlocalchanges
    global uicolor bgcolor fgcolor ctext diffcolors selectbgcolor markbgcolor
    global tabstop limitdiffs autoselect autosellen extdifftool perfile_attrs
    global hideremotes want_ttk have_ttk

    set top .gitkprefs
    set prefstop $top
    if {[winfo exists $top]} {
	raise $top
	return
    }
    foreach v {maxwidth maxgraphpct showneartags showlocalchanges \
		   limitdiffs tabstop perfile_attrs hideremotes want_ttk} {
	set oldprefs($v) [set $v]
    }
    ttk_toplevel $top
    wm title $top [mc "Gitk preferences"]
    make_transient $top .

    if {[set use_notebook [expr {$use_ttk && [info command ::ttk::notebook] ne ""}]]} {
	set notebook [ttk::notebook $top.notebook]
    } else {
	set notebook [${NS}::frame $top.notebook -borderwidth 0 -relief flat]
    }

    lappend pages [prefspage_general $notebook] [mc "General"]
    lappend pages [prefspage_colors $notebook] [mc "Colors"]
    lappend pages [prefspage_fonts $notebook] [mc "Fonts"]
    set col 0
    foreach {page title} $pages {
	if {$use_notebook} {
	    $notebook add $page -text $title
	} else {
	    set btn [${NS}::button $notebook.b_[string map {. X} $page] \
			 -text $title -command [list raise $page]]
	    $page configure -text $title
	    grid $btn -row 0 -column [incr col] -sticky w
	    grid $page -row 1 -column 0 -sticky news -columnspan 100
	}
    }

    if {!$use_notebook} {
	grid columnconfigure $notebook 0 -weight 1
	grid rowconfigure $notebook 1 -weight 1
	raise [lindex $pages 0]
    }

    grid $notebook -sticky news -padx 2 -pady 2
    grid rowconfigure $top 0 -weight 1
    grid columnconfigure $top 0 -weight 1

    ${NS}::frame $top.buts
    ${NS}::button $top.buts.ok -text [mc "OK"] -command prefsok -default active
    ${NS}::button $top.buts.can -text [mc "Cancel"] -command prefscan -default normal
    bind $top <Key-Return> prefsok
    bind $top <Key-Escape> prefscan
    grid $top.buts.ok $top.buts.can
    grid columnconfigure $top.buts 0 -weight 1 -uniform a
    grid columnconfigure $top.buts 1 -weight 1 -uniform a
    grid $top.buts - - -pady 10 -sticky ew
    grid columnconfigure $top 2 -weight 1
    bind $top <Visibility> [list focus $top.buts.ok]
}

proc choose_extdiff {} {
    global extdifftool

    set prog [tk_getOpenFile -title [mc "External diff tool"] -multiple false]
    if {$prog ne {}} {
	set extdifftool $prog
    }
}

proc choosecolor {v vi w x cmd} {
    global $v

    set c [tk_chooseColor -initialcolor [lindex [set $v] $vi] \
	       -title [mc "Gitk: choose color for %s" $x]]
    if {$c eq {}} return
    $w conf -background $c
    lset $v $vi $c
    eval $cmd $c
}

proc setselbg {c} {
    global bglist cflist
    foreach w $bglist {
	$w configure -selectbackground $c
    }
    $cflist tag configure highlight \
	-background [$cflist cget -selectbackground]
    allcanvs itemconf secsel -fill $c
}

# This sets the background color and the color scheme for the whole UI.
# For some reason, tk_setPalette chooses a nasty dark red for selectColor
# if we don't specify one ourselves, which makes the checkbuttons and
# radiobuttons look bad.  This chooses white for selectColor if the
# background color is light, or black if it is dark.
proc setui {c} {
    if {[tk windowingsystem] eq "win32"} { return }
    set bg [winfo rgb . $c]
    set selc black
    if {[lindex $bg 0] + 1.5 * [lindex $bg 1] + 0.5 * [lindex $bg 2] > 100000} {
	set selc white
    }
    tk_setPalette background $c selectColor $selc
}

proc setbg {c} {
    global bglist

    foreach w $bglist {
	$w conf -background $c
    }
}

proc setfg {c} {
    global fglist canv

    foreach w $fglist {
	$w conf -foreground $c
    }
    allcanvs itemconf text -fill $c
    $canv itemconf circle -outline $c
    $canv itemconf markid -outline $c
}

proc prefscan {} {
    global oldprefs prefstop

    foreach v {maxwidth maxgraphpct showneartags showlocalchanges \
		   limitdiffs tabstop perfile_attrs hideremotes want_ttk} {
	global $v
	set $v $oldprefs($v)
    }
    catch {destroy $prefstop}
    unset prefstop
    fontcan
}

proc prefsok {} {
    global maxwidth maxgraphpct
    global oldprefs prefstop showneartags showlocalchanges
    global fontpref mainfont textfont uifont
    global limitdiffs treediffs perfile_attrs
    global hideremotes

    catch {destroy $prefstop}
    unset prefstop
    fontcan
    set fontchanged 0
    if {$mainfont ne $fontpref(mainfont)} {
	set mainfont $fontpref(mainfont)
	parsefont mainfont $mainfont
	eval font configure mainfont [fontflags mainfont]
	eval font configure mainfontbold [fontflags mainfont 1]
	setcoords
	set fontchanged 1
    }
    if {$textfont ne $fontpref(textfont)} {
	set textfont $fontpref(textfont)
	parsefont textfont $textfont
	eval font configure textfont [fontflags textfont]
	eval font configure textfontbold [fontflags textfont 1]
    }
    if {$uifont ne $fontpref(uifont)} {
	set uifont $fontpref(uifont)
	parsefont uifont $uifont
	eval font configure uifont [fontflags uifont]
    }
    settabs
    if {$showlocalchanges != $oldprefs(showlocalchanges)} {
	if {$showlocalchanges} {
	    doshowlocalchanges
	} else {
	    dohidelocalchanges
	}
    }
    if {$limitdiffs != $oldprefs(limitdiffs) ||
	($perfile_attrs && !$oldprefs(perfile_attrs))} {
	# treediffs elements are limited by path;
	# won't have encodings cached if perfile_attrs was just turned on
	catch {unset treediffs}
    }
    if {$fontchanged || $maxwidth != $oldprefs(maxwidth)
	|| $maxgraphpct != $oldprefs(maxgraphpct)} {
	redisplay
    } elseif {$showneartags != $oldprefs(showneartags) ||
	  $limitdiffs != $oldprefs(limitdiffs)} {
	reselectline
    }
    if {$hideremotes != $oldprefs(hideremotes)} {
	rereadrefs
    }
}

proc formatdate {d} {
    global datetimeformat
    if {$d ne {}} {
	# If $datetimeformat includes a timezone, display in the
	# timezone of the argument.  Otherwise, display in local time.
	if {[string match {*%[zZ]*} $datetimeformat]} {
	    if {[catch {set d [clock format [lindex $d 0] -timezone [lindex $d 1] -format $datetimeformat]}]} {
		# Tcl < 8.5 does not support -timezone.  Emulate it by
		# setting TZ (e.g. TZ=<-0430>+04:30).
		global env
		if {[info exists env(TZ)]} {
		    set savedTZ $env(TZ)
		}
		set zone [lindex $d 1]
		set sign [string map {+ - - +} [string index $zone 0]]
		set env(TZ) <$zone>$sign[string range $zone 1 2]:[string range $zone 3 4]
		set d [clock format [lindex $d 0] -format $datetimeformat]
		if {[info exists savedTZ]} {
		    set env(TZ) $savedTZ
		} else {
		    unset env(TZ)
		}
	    }
	} else {
	    set d [clock format [lindex $d 0] -format $datetimeformat]
	}
    }
    return $d
}

# This list of encoding names and aliases is distilled from
# http://www.iana.org/assignments/character-sets.
# Not all of them are supported by Tcl.
set encoding_aliases {
    { ANSI_X3.4-1968 iso-ir-6 ANSI_X3.4-1986 ISO_646.irv:1991 ASCII
      ISO646-US US-ASCII us IBM367 cp367 csASCII }
    { ISO-10646-UTF-1 csISO10646UTF1 }
    { ISO_646.basic:1983 ref csISO646basic1983 }
    { INVARIANT csINVARIANT }
    { ISO_646.irv:1983 iso-ir-2 irv csISO2IntlRefVersion }
    { BS_4730 iso-ir-4 ISO646-GB gb uk csISO4UnitedKingdom }
    { NATS-SEFI iso-ir-8-1 csNATSSEFI }
    { NATS-SEFI-ADD iso-ir-8-2 csNATSSEFIADD }
    { NATS-DANO iso-ir-9-1 csNATSDANO }
    { NATS-DANO-ADD iso-ir-9-2 csNATSDANOADD }
    { SEN_850200_B iso-ir-10 FI ISO646-FI ISO646-SE se csISO10Swedish }
    { SEN_850200_C iso-ir-11 ISO646-SE2 se2 csISO11SwedishForNames }
    { KS_C_5601-1987 iso-ir-149 KS_C_5601-1989 KSC_5601 korean csKSC56011987 }
    { ISO-2022-KR csISO2022KR }
    { EUC-KR csEUCKR }
    { ISO-2022-JP csISO2022JP }
    { ISO-2022-JP-2 csISO2022JP2 }
    { JIS_C6220-1969-jp JIS_C6220-1969 iso-ir-13 katakana x0201-7
      csISO13JISC6220jp }
    { JIS_C6220-1969-ro iso-ir-14 jp ISO646-JP csISO14JISC6220ro }
    { IT iso-ir-15 ISO646-IT csISO15Italian }
    { PT iso-ir-16 ISO646-PT csISO16Portuguese }
    { ES iso-ir-17 ISO646-ES csISO17Spanish }
    { greek7-old iso-ir-18 csISO18Greek7Old }
    { latin-greek iso-ir-19 csISO19LatinGreek }
    { DIN_66003 iso-ir-21 de ISO646-DE csISO21German }
    { NF_Z_62-010_(1973) iso-ir-25 ISO646-FR1 csISO25French }
    { Latin-greek-1 iso-ir-27 csISO27LatinGreek1 }
    { ISO_5427 iso-ir-37 csISO5427Cyrillic }
    { JIS_C6226-1978 iso-ir-42 csISO42JISC62261978 }
    { BS_viewdata iso-ir-47 csISO47BSViewdata }
    { INIS iso-ir-49 csISO49INIS }
    { INIS-8 iso-ir-50 csISO50INIS8 }
    { INIS-cyrillic iso-ir-51 csISO51INISCyrillic }
    { ISO_5427:1981 iso-ir-54 ISO5427Cyrillic1981 }
    { ISO_5428:1980 iso-ir-55 csISO5428Greek }
    { GB_1988-80 iso-ir-57 cn ISO646-CN csISO57GB1988 }
    { GB_2312-80 iso-ir-58 chinese csISO58GB231280 }
    { NS_4551-1 iso-ir-60 ISO646-NO no csISO60DanishNorwegian
      csISO60Norwegian1 }
    { NS_4551-2 ISO646-NO2 iso-ir-61 no2 csISO61Norwegian2 }
    { NF_Z_62-010 iso-ir-69 ISO646-FR fr csISO69French }
    { videotex-suppl iso-ir-70 csISO70VideotexSupp1 }
    { PT2 iso-ir-84 ISO646-PT2 csISO84Portuguese2 }
    { ES2 iso-ir-85 ISO646-ES2 csISO85Spanish2 }
    { MSZ_7795.3 iso-ir-86 ISO646-HU hu csISO86Hungarian }
    { JIS_C6226-1983 iso-ir-87 x0208 JIS_X0208-1983 csISO87JISX0208 }
    { greek7 iso-ir-88 csISO88Greek7 }
    { ASMO_449 ISO_9036 arabic7 iso-ir-89 csISO89ASMO449 }
    { iso-ir-90 csISO90 }
    { JIS_C6229-1984-a iso-ir-91 jp-ocr-a csISO91JISC62291984a }
    { JIS_C6229-1984-b iso-ir-92 ISO646-JP-OCR-B jp-ocr-b
      csISO92JISC62991984b }
    { JIS_C6229-1984-b-add iso-ir-93 jp-ocr-b-add csISO93JIS62291984badd }
    { JIS_C6229-1984-hand iso-ir-94 jp-ocr-hand csISO94JIS62291984hand }
    { JIS_C6229-1984-hand-add iso-ir-95 jp-ocr-hand-add
      csISO95JIS62291984handadd }
    { JIS_C6229-1984-kana iso-ir-96 csISO96JISC62291984kana }
    { ISO_2033-1983 iso-ir-98 e13b csISO2033 }
    { ANSI_X3.110-1983 iso-ir-99 CSA_T500-1983 NAPLPS csISO99NAPLPS }
    { ISO_8859-1:1987 iso-ir-100 ISO_8859-1 ISO-8859-1 latin1 l1 IBM819
      CP819 csISOLatin1 }
    { ISO_8859-2:1987 iso-ir-101 ISO_8859-2 ISO-8859-2 latin2 l2 csISOLatin2 }
    { T.61-7bit iso-ir-102 csISO102T617bit }
    { T.61-8bit T.61 iso-ir-103 csISO103T618bit }
    { ISO_8859-3:1988 iso-ir-109 ISO_8859-3 ISO-8859-3 latin3 l3 csISOLatin3 }
    { ISO_8859-4:1988 iso-ir-110 ISO_8859-4 ISO-8859-4 latin4 l4 csISOLatin4 }
    { ECMA-cyrillic iso-ir-111 KOI8-E csISO111ECMACyrillic }
    { CSA_Z243.4-1985-1 iso-ir-121 ISO646-CA csa7-1 ca csISO121Canadian1 }
    { CSA_Z243.4-1985-2 iso-ir-122 ISO646-CA2 csa7-2 csISO122Canadian2 }
    { CSA_Z243.4-1985-gr iso-ir-123 csISO123CSAZ24341985gr }
    { ISO_8859-6:1987 iso-ir-127 ISO_8859-6 ISO-8859-6 ECMA-114 ASMO-708
      arabic csISOLatinArabic }
    { ISO_8859-6-E csISO88596E ISO-8859-6-E }
    { ISO_8859-6-I csISO88596I ISO-8859-6-I }
    { ISO_8859-7:1987 iso-ir-126 ISO_8859-7 ISO-8859-7 ELOT_928 ECMA-118
      greek greek8 csISOLatinGreek }
    { T.101-G2 iso-ir-128 csISO128T101G2 }
    { ISO_8859-8:1988 iso-ir-138 ISO_8859-8 ISO-8859-8 hebrew
      csISOLatinHebrew }
    { ISO_8859-8-E csISO88598E ISO-8859-8-E }
    { ISO_8859-8-I csISO88598I ISO-8859-8-I }
    { CSN_369103 iso-ir-139 csISO139CSN369103 }
    { JUS_I.B1.002 iso-ir-141 ISO646-YU js yu csISO141JUSIB1002 }
    { ISO_6937-2-add iso-ir-142 csISOTextComm }
    { IEC_P27-1 iso-ir-143 csISO143IECP271 }
    { ISO_8859-5:1988 iso-ir-144 ISO_8859-5 ISO-8859-5 cyrillic
      csISOLatinCyrillic }
    { JUS_I.B1.003-serb iso-ir-146 serbian csISO146Serbian }
    { JUS_I.B1.003-mac macedonian iso-ir-147 csISO147Macedonian }
    { ISO_8859-9:1989 iso-ir-148 ISO_8859-9 ISO-8859-9 latin5 l5 csISOLatin5 }
    { greek-ccitt iso-ir-150 csISO150 csISO150GreekCCITT }
    { NC_NC00-10:81 cuba iso-ir-151 ISO646-CU csISO151Cuba }
    { ISO_6937-2-25 iso-ir-152 csISO6937Add }
    { GOST_19768-74 ST_SEV_358-88 iso-ir-153 csISO153GOST1976874 }
    { ISO_8859-supp iso-ir-154 latin1-2-5 csISO8859Supp }
    { ISO_10367-box iso-ir-155 csISO10367Box }
    { ISO-8859-10 iso-ir-157 l6 ISO_8859-10:1992 csISOLatin6 latin6 }
    { latin-lap lap iso-ir-158 csISO158Lap }
    { JIS_X0212-1990 x0212 iso-ir-159 csISO159JISX02121990 }
    { DS_2089 DS2089 ISO646-DK dk csISO646Danish }
    { us-dk csUSDK }
    { dk-us csDKUS }
    { JIS_X0201 X0201 csHalfWidthKatakana }
    { KSC5636 ISO646-KR csKSC5636 }
    { ISO-10646-UCS-2 csUnicode }
    { ISO-10646-UCS-4 csUCS4 }
    { DEC-MCS dec csDECMCS }
    { hp-roman8 roman8 r8 csHPRoman8 }
    { macintosh mac csMacintosh }
    { IBM037 cp037 ebcdic-cp-us ebcdic-cp-ca ebcdic-cp-wt ebcdic-cp-nl
      csIBM037 }
    { IBM038 EBCDIC-INT cp038 csIBM038 }
    { IBM273 CP273 csIBM273 }
    { IBM274 EBCDIC-BE CP274 csIBM274 }
    { IBM275 EBCDIC-BR cp275 csIBM275 }
    { IBM277 EBCDIC-CP-DK EBCDIC-CP-NO csIBM277 }
    { IBM278 CP278 ebcdic-cp-fi ebcdic-cp-se csIBM278 }
    { IBM280 CP280 ebcdic-cp-it csIBM280 }
    { IBM281 EBCDIC-JP-E cp281 csIBM281 }
    { IBM284 CP284 ebcdic-cp-es csIBM284 }
    { IBM285 CP285 ebcdic-cp-gb csIBM285 }
    { IBM290 cp290 EBCDIC-JP-kana csIBM290 }
    { IBM297 cp297 ebcdic-cp-fr csIBM297 }
    { IBM420 cp420 ebcdic-cp-ar1 csIBM420 }
    { IBM423 cp423 ebcdic-cp-gr csIBM423 }
    { IBM424 cp424 ebcdic-cp-he csIBM424 }
    { IBM437 cp437 437 csPC8CodePage437 }
    { IBM500 CP500 ebcdic-cp-be ebcdic-cp-ch csIBM500 }
    { IBM775 cp775 csPC775Baltic }
    { IBM850 cp850 850 csPC850Multilingual }
    { IBM851 cp851 851 csIBM851 }
    { IBM852 cp852 852 csPCp852 }
    { IBM855 cp855 855 csIBM855 }
    { IBM857 cp857 857 csIBM857 }
    { IBM860 cp860 860 csIBM860 }
    { IBM861 cp861 861 cp-is csIBM861 }
    { IBM862 cp862 862 csPC862LatinHebrew }
    { IBM863 cp863 863 csIBM863 }
    { IBM864 cp864 csIBM864 }
    { IBM865 cp865 865 csIBM865 }
    { IBM866 cp866 866 csIBM866 }
    { IBM868 CP868 cp-ar csIBM868 }
    { IBM869 cp869 869 cp-gr csIBM869 }
    { IBM870 CP870 ebcdic-cp-roece ebcdic-cp-yu csIBM870 }
    { IBM871 CP871 ebcdic-cp-is csIBM871 }
    { IBM880 cp880 EBCDIC-Cyrillic csIBM880 }
    { IBM891 cp891 csIBM891 }
    { IBM903 cp903 csIBM903 }
    { IBM904 cp904 904 csIBBM904 }
    { IBM905 CP905 ebcdic-cp-tr csIBM905 }
    { IBM918 CP918 ebcdic-cp-ar2 csIBM918 }
    { IBM1026 CP1026 csIBM1026 }
    { EBCDIC-AT-DE csIBMEBCDICATDE }
    { EBCDIC-AT-DE-A csEBCDICATDEA }
    { EBCDIC-CA-FR csEBCDICCAFR }
    { EBCDIC-DK-NO csEBCDICDKNO }
    { EBCDIC-DK-NO-A csEBCDICDKNOA }
    { EBCDIC-FI-SE csEBCDICFISE }
    { EBCDIC-FI-SE-A csEBCDICFISEA }
    { EBCDIC-FR csEBCDICFR }
    { EBCDIC-IT csEBCDICIT }
    { EBCDIC-PT csEBCDICPT }
    { EBCDIC-ES csEBCDICES }
    { EBCDIC-ES-A csEBCDICESA }
    { EBCDIC-ES-S csEBCDICESS }
    { EBCDIC-UK csEBCDICUK }
    { EBCDIC-US csEBCDICUS }
    { UNKNOWN-8BIT csUnknown8BiT }
    { MNEMONIC csMnemonic }
    { MNEM csMnem }
    { VISCII csVISCII }
    { VIQR csVIQR }
    { KOI8-R csKOI8R }
    { IBM00858 CCSID00858 CP00858 PC-Multilingual-850+euro }
    { IBM00924 CCSID00924 CP00924 ebcdic-Latin9--euro }
    { IBM01140 CCSID01140 CP01140 ebcdic-us-37+euro }
    { IBM01141 CCSID01141 CP01141 ebcdic-de-273+euro }
    { IBM01142 CCSID01142 CP01142 ebcdic-dk-277+euro ebcdic-no-277+euro }
    { IBM01143 CCSID01143 CP01143 ebcdic-fi-278+euro ebcdic-se-278+euro }
    { IBM01144 CCSID01144 CP01144 ebcdic-it-280+euro }
    { IBM01145 CCSID01145 CP01145 ebcdic-es-284+euro }
    { IBM01146 CCSID01146 CP01146 ebcdic-gb-285+euro }
    { IBM01147 CCSID01147 CP01147 ebcdic-fr-297+euro }
    { IBM01148 CCSID01148 CP01148 ebcdic-international-500+euro }
    { IBM01149 CCSID01149 CP01149 ebcdic-is-871+euro }
    { IBM1047 IBM-1047 }
    { PTCP154 csPTCP154 PT154 CP154 Cyrillic-Asian }
    { Amiga-1251 Ami1251 Amiga1251 Ami-1251 }
    { UNICODE-1-1 csUnicode11 }
    { CESU-8 csCESU-8 }
    { BOCU-1 csBOCU-1 }
    { UNICODE-1-1-UTF-7 csUnicode11UTF7 }
    { ISO-8859-14 iso-ir-199 ISO_8859-14:1998 ISO_8859-14 latin8 iso-celtic
      l8 }
    { ISO-8859-15 ISO_8859-15 Latin-9 }
    { ISO-8859-16 iso-ir-226 ISO_8859-16:2001 ISO_8859-16 latin10 l10 }
    { GBK CP936 MS936 windows-936 }
    { JIS_Encoding csJISEncoding }
    { Shift_JIS MS_Kanji csShiftJIS ShiftJIS Shift-JIS }
    { Extended_UNIX_Code_Packed_Format_for_Japanese csEUCPkdFmtJapanese
      EUC-JP }
    { Extended_UNIX_Code_Fixed_Width_for_Japanese csEUCFixWidJapanese }
    { ISO-10646-UCS-Basic csUnicodeASCII }
    { ISO-10646-Unicode-Latin1 csUnicodeLatin1 ISO-10646 }
    { ISO-Unicode-IBM-1261 csUnicodeIBM1261 }
    { ISO-Unicode-IBM-1268 csUnicodeIBM1268 }
    { ISO-Unicode-IBM-1276 csUnicodeIBM1276 }
    { ISO-Unicode-IBM-1264 csUnicodeIBM1264 }
    { ISO-Unicode-IBM-1265 csUnicodeIBM1265 }
    { ISO-8859-1-Windows-3.0-Latin-1 csWindows30Latin1 }
    { ISO-8859-1-Windows-3.1-Latin-1 csWindows31Latin1 }
    { ISO-8859-2-Windows-Latin-2 csWindows31Latin2 }
    { ISO-8859-9-Windows-Latin-5 csWindows31Latin5 }
    { Adobe-Standard-Encoding csAdobeStandardEncoding }
    { Ventura-US csVenturaUS }
    { Ventura-International csVenturaInternational }
    { PC8-Danish-Norwegian csPC8DanishNorwegian }
    { PC8-Turkish csPC8Turkish }
    { IBM-Symbols csIBMSymbols }
    { IBM-Thai csIBMThai }
    { HP-Legal csHPLegal }
    { HP-Pi-font csHPPiFont }
    { HP-Math8 csHPMath8 }
    { Adobe-Symbol-Encoding csHPPSMath }
    { HP-DeskTop csHPDesktop }
    { Ventura-Math csVenturaMath }
    { Microsoft-Publishing csMicrosoftPublishing }
    { Windows-31J csWindows31J }
    { GB2312 csGB2312 }
    { Big5 csBig5 }
}

proc tcl_encoding {enc} {
    global encoding_aliases tcl_encoding_cache
    if {[info exists tcl_encoding_cache($enc)]} {
	return $tcl_encoding_cache($enc)
    }
    set names [encoding names]
    set lcnames [string tolower $names]
    set enc [string tolower $enc]
    set i [lsearch -exact $lcnames $enc]
    if {$i < 0} {
	# look for "isonnn" instead of "iso-nnn" or "iso_nnn"
	if {[regsub {^(iso|cp|ibm|jis)[-_]} $enc {\1} encx]} {
	    set i [lsearch -exact $lcnames $encx]
	}
    }
    if {$i < 0} {
	foreach l $encoding_aliases {
	    set ll [string tolower $l]
	    if {[lsearch -exact $ll $enc] < 0} continue
	    # look through the aliases for one that tcl knows about
	    foreach e $ll {
		set i [lsearch -exact $lcnames $e]
		if {$i < 0} {
		    if {[regsub {^(iso|cp|ibm|jis)[-_]} $e {\1} ex]} {
			set i [lsearch -exact $lcnames $ex]
		    }
		}
		if {$i >= 0} break
	    }
	    break
	}
    }
    set tclenc {}
    if {$i >= 0} {
	set tclenc [lindex $names $i]
    }
    set tcl_encoding_cache($enc) $tclenc
    return $tclenc
}

proc gitattr {path attr default} {
    global path_attr_cache
    if {[info exists path_attr_cache($attr,$path)]} {
	set r $path_attr_cache($attr,$path)
    } else {
	set r "unspecified"
	if {![catch {set line [exec git check-attr $attr -- $path]}]} {
	    regexp "(.*): $attr: (.*)" $line m f r
	}
	set path_attr_cache($attr,$path) $r
    }
    if {$r eq "unspecified"} {
	return $default
    }
    return $r
}

proc cache_gitattr {attr pathlist} {
    global path_attr_cache
    set newlist {}
    foreach path $pathlist {
	if {![info exists path_attr_cache($attr,$path)]} {
	    lappend newlist $path
	}
    }
    set lim 1000
    if {[tk windowingsystem] == "win32"} {
	# windows has a 32k limit on the arguments to a command...
	set lim 30
    }
    while {$newlist ne {}} {
	set head [lrange $newlist 0 [expr {$lim - 1}]]
	set newlist [lrange $newlist $lim end]
	if {![catch {set rlist [eval exec git check-attr $attr -- $head]}]} {
	    foreach row [split $rlist "\n"] {
		if {[regexp "(.*): $attr: (.*)" $row m path value]} {
		    if {[string index $path 0] eq "\""} {
			set path [encoding convertfrom [lindex $path 0]]
		    }
		    set path_attr_cache($attr,$path) $value
		}
	    }
	}
    }
}

proc get_path_encoding {path} {
    global gui_encoding perfile_attrs
    set tcl_enc $gui_encoding
    if {$path ne {} && $perfile_attrs} {
	set enc2 [tcl_encoding [gitattr $path encoding $tcl_enc]]
	if {$enc2 ne {}} {
	    set tcl_enc $enc2
	}
    }
    return $tcl_enc
}

# First check that Tcl/Tk is recent enough
if {[catch {package require Tk 8.4} err]} {
    show_error {} . "Sorry, gitk cannot run with this version of Tcl/Tk.\n\
		     Gitk requires at least Tcl/Tk 8.4." list
    exit 1
}

# on OSX bring the current Wish process window to front
if {[tk windowingsystem] eq "aqua"} {
    exec osascript -e [format {
        tell application "System Events"
            set frontmost of processes whose unix id is %d to true
        end tell
    } [pid] ]
}

# Unset GIT_TRACE var if set
if { [info exists ::env(GIT_TRACE)] } {
    unset ::env(GIT_TRACE)
}

# defaults...
set wrcomcmd "git diff-tree --stdin -p --pretty"

set gitencoding {}
catch {
    set gitencoding [exec git config --get i18n.commitencoding]
}
catch {
    set gitencoding [exec git config --get i18n.logoutputencoding]
}
if {$gitencoding == ""} {
    set gitencoding "utf-8"
}
set tclencoding [tcl_encoding $gitencoding]
if {$tclencoding == {}} {
    puts stderr "Warning: encoding $gitencoding is not supported by Tcl/Tk"
}

set gui_encoding [encoding system]
catch {
    set enc [exec git config --get gui.encoding]
    if {$enc ne {}} {
	set tclenc [tcl_encoding $enc]
	if {$tclenc ne {}} {
	    set gui_encoding $tclenc
	} else {
	    puts stderr "Warning: encoding $enc is not supported by Tcl/Tk"
	}
    }
}

set log_showroot true
catch {
    set log_showroot [exec git config --bool --get log.showroot]
}

if {[tk windowingsystem] eq "aqua"} {
    set mainfont {{Lucida Grande} 9}
    set textfont {Monaco 9}
    set uifont {{Lucida Grande} 9 bold}
} elseif {![catch {::tk::pkgconfig get fontsystem} xft] && $xft eq "xft"} {
    # fontconfig!
    set mainfont {sans 9}
    set textfont {monospace 9}
    set uifont {sans 9 bold}
} else {
    set mainfont {Helvetica 9}
    set textfont {Courier 9}
    set uifont {Helvetica 9 bold}
}
set tabstop 8
set findmergefiles 0
set maxgraphpct 50
set maxwidth 16
set revlistorder 0
set fastdate 0
set uparrowlen 5
set downarrowlen 5
set mingaplen 100
set cmitmode "patch"
set wrapcomment "none"
set showneartags 1
set hideremotes 0
set maxrefs 20
set visiblerefs {"master"}
set maxlinelen 200
set showlocalchanges 1
set limitdiffs 1
set datetimeformat "%Y-%m-%d %H:%M:%S"
set autoselect 1
set autosellen 40
set perfile_attrs 0
set want_ttk 1

if {[tk windowingsystem] eq "aqua"} {
    set extdifftool "opendiff"
} else {
    set extdifftool "meld"
}

set colors {green red blue magenta darkgrey brown orange}
if {[tk windowingsystem] eq "win32"} {
    set uicolor SystemButtonFace
    set uifgcolor SystemButtonText
    set uifgdisabledcolor SystemDisabledText
    set bgcolor SystemWindow
    set fgcolor SystemWindowText
    set selectbgcolor SystemHighlight
} else {
    set uicolor grey85
    set uifgcolor black
    set uifgdisabledcolor "#999"
    set bgcolor white
    set fgcolor black
    set selectbgcolor gray85
}
set diffcolors {red "#00a000" blue}
set diffcontext 3
set mergecolors {red blue green purple brown "#009090" magenta "#808000" "#009000" "#ff0080" cyan "#b07070" "#70b0f0" "#70f0b0" "#f0b070" "#ff70b0"}
set ignorespace 0
set worddiff ""
set markbgcolor "#e0e0ff"

set headbgcolor green
set headfgcolor black
set headoutlinecolor black
set remotebgcolor #ffddaa
set tagbgcolor yellow
set tagfgcolor black
set tagoutlinecolor black
set reflinecolor black
set filesepbgcolor #aaaaaa
set filesepfgcolor black
set linehoverbgcolor #ffff80
set linehoverfgcolor black
set linehoveroutlinecolor black
set mainheadcirclecolor yellow
set workingfilescirclecolor red
set indexcirclecolor green
set circlecolors {white blue gray blue blue}
set linkfgcolor blue
set circleoutlinecolor $fgcolor
set foundbgcolor yellow
set currentsearchhitbgcolor orange

# button for popping up context menus
if {[tk windowingsystem] eq "aqua"} {
    set ctxbut <Button-2>
} else {
    set ctxbut <Button-3>
}

## For msgcat loading, first locate the installation location.
if { [info exists ::env(GITK_MSGSDIR)] } {
    ## Msgsdir was manually set in the environment.
    set gitk_msgsdir $::env(GITK_MSGSDIR)
} else {
    ## Let's guess the prefix from argv0.
    set gitk_prefix [file dirname [file dirname [file normalize $argv0]]]
    set gitk_libdir [file join $gitk_prefix share gitk lib]
    set gitk_msgsdir [file join $gitk_libdir msgs]
    unset gitk_prefix
}

## Internationalization (i18n) through msgcat and gettext. See
## http://www.gnu.org/software/gettext/manual/html_node/Tcl.html
package require msgcat
namespace import ::msgcat::mc
## And eventually load the actual message catalog
::msgcat::mcload $gitk_msgsdir

catch {
    # follow the XDG base directory specification by default. See
    # http://standards.freedesktop.org/basedir-spec/basedir-spec-latest.html
    if {[info exists env(XDG_CONFIG_HOME)] && $env(XDG_CONFIG_HOME) ne ""} {
	# XDG_CONFIG_HOME environment variable is set
	set config_file [file join $env(XDG_CONFIG_HOME) git gitk]
	set config_file_tmp [file join $env(XDG_CONFIG_HOME) git gitk-tmp]
    } else {
	# default XDG_CONFIG_HOME
	set config_file "~/.config/git/gitk"
	set config_file_tmp "~/.config/git/gitk-tmp"
    }
    if {![file exists $config_file]} {
	# for backward compatibility use the old config file if it exists
	if {[file exists "~/.gitk"]} {
	    set config_file "~/.gitk"
	    set config_file_tmp "~/.gitk-tmp"
	} elseif {![file exists [file dirname $config_file]]} {
	    file mkdir [file dirname $config_file]
	}
    }
    source $config_file
}

set config_variables {
    mainfont textfont uifont tabstop findmergefiles maxgraphpct maxwidth
    cmitmode wrapcomment autoselect autosellen showneartags maxrefs visiblerefs
    hideremotes showlocalchanges datetimeformat limitdiffs uicolor want_ttk
    bgcolor fgcolor uifgcolor uifgdisabledcolor colors diffcolors mergecolors
    markbgcolor diffcontext selectbgcolor foundbgcolor currentsearchhitbgcolor
    extdifftool perfile_attrs headbgcolor headfgcolor headoutlinecolor
    remotebgcolor tagbgcolor tagfgcolor tagoutlinecolor reflinecolor
    filesepbgcolor filesepfgcolor linehoverbgcolor linehoverfgcolor
    linehoveroutlinecolor mainheadcirclecolor workingfilescirclecolor
    indexcirclecolor circlecolors linkfgcolor circleoutlinecolor
}

parsefont mainfont $mainfont
eval font create mainfont [fontflags mainfont]
eval font create mainfontbold [fontflags mainfont 1]

parsefont textfont $textfont
eval font create textfont [fontflags textfont]
eval font create textfontbold [fontflags textfont 1]

parsefont uifont $uifont
eval font create uifont [fontflags uifont]

setui $uicolor

setoptions

# check that we can find a .git directory somewhere...
if {[catch {set gitdir [exec git rev-parse --git-dir]}]} {
    show_error {} . [mc "Cannot find a git repository here."]
    exit 1
}

set selecthead {}
set selectheadid {}

set revtreeargs {}
set cmdline_files {}
set i 0
set revtreeargscmd {}
foreach arg $argv {
    switch -glob -- $arg {
	"" { }
	"--" {
	    set cmdline_files [lrange $argv [expr {$i + 1}] end]
	    break
	}
	"--select-commit=*" {
	    set selecthead [string range $arg 16 end]
	}
	"--argscmd=*" {
	    set revtreeargscmd [string range $arg 10 end]
	}
	default {
	    lappend revtreeargs $arg
	}
    }
    incr i
}

if {$selecthead eq "HEAD"} {
    set selecthead {}
}

if {$i >= [llength $argv] && $revtreeargs ne {}} {
    # no -- on command line, but some arguments (other than --argscmd)
    if {[catch {
	set f [eval exec git rev-parse --no-revs --no-flags $revtreeargs]
	set cmdline_files [split $f "\n"]
	set n [llength $cmdline_files]
	set revtreeargs [lrange $revtreeargs 0 end-$n]
	# Unfortunately git rev-parse doesn't produce an error when
	# something is both a revision and a filename.  To be consistent
	# with git log and git rev-list, check revtreeargs for filenames.
	foreach arg $revtreeargs {
	    if {[file exists $arg]} {
		show_error {} . [mc "Ambiguous argument '%s': both revision\
				 and filename" $arg]
		exit 1
	    }
	}
    } err]} {
	# unfortunately we get both stdout and stderr in $err,
	# so look for "fatal:".
	set i [string first "fatal:" $err]
	if {$i > 0} {
	    set err [string range $err [expr {$i + 6}] end]
	}
	show_error {} . "[mc "Bad arguments to gitk:"]\n$err"
	exit 1
    }
}

set nullid "0000000000000000000000000000000000000000"
set nullid2 "0000000000000000000000000000000000000001"
set nullfile "/dev/null"

set have_tk85 [expr {[package vcompare $tk_version "8.5"] >= 0}]
if {![info exists have_ttk]} {
    set have_ttk [llength [info commands ::ttk::style]]
}
set use_ttk [expr {$have_ttk && $want_ttk}]
set NS [expr {$use_ttk ? "ttk" : ""}]

regexp {^git version ([\d.]*\d)} [exec git version] _ git_version

set show_notes {}
if {[package vcompare $git_version "1.6.6.2"] >= 0} {
    set show_notes "--show-notes"
}

set appname "gitk"

set runq {}
set history {}
set historyindex 0
set fh_serial 0
set nhl_names {}
set highlight_paths {}
set findpattern {}
set searchdirn -forwards
set boldids {}
set boldnameids {}
set diffelide {0 0}
set markingmatches 0
set linkentercount 0
set need_redisplay 0
set nrows_drawn 0
set firsttabstop 0

set nextviewnum 1
set curview 0
set selectedview 0
set selectedhlview [mc "None"]
set highlight_related [mc "None"]
set highlight_files {}
set viewfiles(0) {}
set viewperm(0) 0
set viewargs(0) {}
set viewargscmd(0) {}

set selectedline {}
set numcommits 0
set loginstance 0
set cmdlineok 0
set stopped 0
set stuffsaved 0
set patchnum 0
set lserial 0
set hasworktree [hasworktree]
set cdup {}
if {[expr {[exec git rev-parse --is-inside-work-tree] == "true"}]} {
    set cdup [exec git rev-parse --show-cdup]
}
set worktree [exec git rev-parse --show-toplevel]
setcoords
makewindow
catch {
    image create photo gitlogo      -width 16 -height 16

    image create photo gitlogominus -width  4 -height  2
    gitlogominus put #C00000 -to 0 0 4 2
    gitlogo copy gitlogominus -to  1 5
    gitlogo copy gitlogominus -to  6 5
    gitlogo copy gitlogominus -to 11 5
    image delete gitlogominus

    image create photo gitlogoplus  -width  4 -height  4
    gitlogoplus  put #008000 -to 1 0 3 4
    gitlogoplus  put #008000 -to 0 1 4 3
    gitlogo copy gitlogoplus  -to  1 9
    gitlogo copy gitlogoplus  -to  6 9
    gitlogo copy gitlogoplus  -to 11 9
    image delete gitlogoplus

    image create photo gitlogo32    -width 32 -height 32
    gitlogo32 copy gitlogo -zoom 2 2

    wm iconphoto . -default gitlogo gitlogo32
}
# wait for the window to become visible
tkwait visibility .
wm title . "$appname: [reponame]"
update
readrefs

if {$cmdline_files ne {} || $revtreeargs ne {} || $revtreeargscmd ne {}} {
    # create a view for the files/dirs specified on the command line
    set curview 1
    set selectedview 1
    set nextviewnum 2
    set viewname(1) [mc "Command line"]
    set viewfiles(1) $cmdline_files
    set viewargs(1) $revtreeargs
    set viewargscmd(1) $revtreeargscmd
    set viewperm(1) 0
    set vdatemode(1) 0
    addviewmenu 1
    .bar.view entryconf [mca "Edit view..."] -state normal
    .bar.view entryconf [mca "Delete view"] -state normal
}

if {[info exists permviews]} {
    foreach v $permviews {
	set n $nextviewnum
	incr nextviewnum
	set viewname($n) [lindex $v 0]
	set viewfiles($n) [lindex $v 1]
	set viewargs($n) [lindex $v 2]
	set viewargscmd($n) [lindex $v 3]
	set viewperm($n) 1
	addviewmenu $n
    }
}

if {[tk windowingsystem] eq "win32"} {
    focus -force .
}

getcommits {}

# Local variables:
# mode: tcl
# indent-tabs-mode: t
# tab-width: 8
# End:
