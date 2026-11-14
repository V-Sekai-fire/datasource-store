# The read-ahead scorer and the compaction trigger. Port of `ra_depth` and `should_compact`
# in `fdb_vfs.c`.
#
# A page miss is a network round trip, so a VFS over FoundationDB lives or dies on read-ahead.
# The scorer does not pick a depth. It scores the access pattern, and the numbers are the
# model's, not ones chosen here:
#
#   forward page, gap of 8 or less   score + 2, capped at 12
#   random page, a scan is running   score - 1
#   random page, no scan             score - 4, floored at 0
#   score of 6 or more               escalate read-ahead
#   score of 10 or more              full depth, 256 pages or 1 MB
#
# So a point read pays for no read-ahead, and a table scan escalates after three pages.
#
# Pure: the state is a score and the last page. A zeroed file starts at (0, 0), which is how
# SQLite hands the C a file object.
#
# SPDX-License-Identifier: Apache-2.0 OR MIT

comptime RA_GAP = 8
comptime RA_SCORE_STEP = 2
comptime RA_SCORE_CAP = 12
comptime RA_DECAY_SCANNING = 1
comptime RA_DECAY_RANDOM = 4
comptime RA_ESCALATE = 6
comptime RA_FULL = 10

# Full depth is 256 pages or 1 MB, whichever is smaller, which at a 4 KiB page is both.
comptime RA_MAX_PAGES = 256
comptime RA_STEP_PAGES = 32


@fieldwise_init
struct ReadAhead(Copyable, Movable):
    var score: Int
    var last: Int  # a page number, 0 to 2^32 - 1

    def __init__(out self):
        self.score = 0
        self.last = 0

    # Move the score by what this page number says about the pattern, and answer how many
    # pages are worth fetching ahead.
    def depth(mut self, pgno: Int) -> Int:
        var gap = pgno - self.last
        if gap > 0 and gap <= RA_GAP:
            self.score += RA_SCORE_STEP
            if self.score > RA_SCORE_CAP:
                self.score = RA_SCORE_CAP
        elif self.score >= RA_ESCALATE:
            self.score -= RA_DECAY_SCANNING
        else:
            self.score -= RA_DECAY_RANDOM
            if self.score < 0:
                self.score = 0
        self.last = pgno
        if self.score >= RA_FULL:
            return RA_MAX_PAGES
        if self.score >= RA_ESCALATE:
            return RA_STEP_PAGES
        return 0


# Compact when the log is as large as the base. A ratio has no units to tune, and it moves
# with the load. A quiet actor, with nothing in the log, never compacts.
def should_compact(log_pages: UInt64, base_pages: UInt64) -> Bool:
    return log_pages > 0 and base_pages <= log_pages
