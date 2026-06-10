//! Small fuzzy matching primitive for process labels and categories.
//! The scoring favors ordered character matches and early label matches without pulling a larger fuzzy-search dependency into the TUI path.

const std = @import("std");

const first_char_match_bonus = 10;
const match_following_separator_bonus = 20;
const camel_case_match_bonus = 20;
const adjacent_match_bonus = 5;
const unmatched_leading_char_penalty = -5;
const max_unmatched_leading_char_penalty = -15;

pub const Match = struct {
    index: usize,
    score: i32,
};

pub fn find(allocator: std.mem.Allocator, pattern: []const u8, labels: []const []const u8) ![]Match {
    if (pattern.len == 0) return allocator.alloc(Match, 0);

    var matches = std.array_list.Managed(Match).init(allocator);
    errdefer matches.deinit();

    for (labels, 0..) |label, index| {
        if (score(pattern, label)) |value| {
            try matches.append(.{ .index = index, .score = value });
        }
    }

    sortMatches(matches.items);
    return matches.toOwnedSlice();
}

pub fn sortMatches(matches: []Match) void {
    std.mem.sort(Match, matches, {}, lessMatch);
}

pub fn score(pattern: []const u8, candidate: []const u8) ?i32 {
    if (pattern.len == 0) return null;
    if (candidate.len == 0) return null;

    var total: i32 = 0;
    var pattern_index: usize = 0;
    var best_score: i32 = -1;
    var matched_index: i32 = -1;
    var matched_count: usize = 0;
    var current_adjacent_bonus: i32 = 0;
    var last: u8 = 0;
    var last_index: i32 = 0;

    var j: usize = 0;
    while (j < candidate.len) : (j += 1) {
        const c = candidate[j];
        if (pattern_index < pattern.len and equalFold(c, pattern[pattern_index])) {
            var candidate_score: i32 = 0;
            if (j == 0) candidate_score += first_char_match_bonus;
            if (std.ascii.isLower(last) and std.ascii.isUpper(c)) candidate_score += camel_case_match_bonus;
            if (j != 0 and isSeparator(last)) candidate_score += match_following_separator_bonus;
            if (matched_count > 0) {
                const bonus = adjacentCharBonus(last_index, @intCast(matched_index), current_adjacent_bonus);
                candidate_score += bonus;
                current_adjacent_bonus += bonus;
            }
            if (candidate_score > best_score) {
                best_score = candidate_score;
                matched_index = @intCast(j);
            }
        }

        const next_pattern = if (pattern_index < pattern.len - 1) pattern[pattern_index + 1] else 0;
        const next_candidate = if (j + 1 < candidate.len) candidate[j + 1] else 0;
        if (equalFold(next_pattern, next_candidate) or next_candidate == 0) {
            if (matched_index > -1) {
                if (matched_count == 0) {
                    const penalty = matched_index * unmatched_leading_char_penalty;
                    best_score += @max(penalty, max_unmatched_leading_char_penalty);
                }
                total += best_score;
                matched_count += 1;
                best_score = -1;
                pattern_index += 1;
            }
        }

        last_index = @intCast(j);
        last = c;
    }

    total += @as(i32, @intCast(matched_count)) - @as(i32, @intCast(candidate.len));
    if (matched_count == pattern.len) return total;
    return null;
}

fn lessMatch(_: void, a: Match, b: Match) bool {
    if (a.score == b.score) return a.index < b.index;
    return a.score > b.score;
}

fn equalFold(a: u8, b: u8) bool {
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn adjacentCharBonus(index: i32, last_match: i32, current_bonus: i32) i32 {
    if (last_match == index) return current_bonus * 2 + adjacent_match_bonus;
    return 0;
}

fn isSeparator(c: u8) bool {
    return c == '/' or c == '-' or c == '_' or c == ' ' or c == '.' or c == '\\';
}
