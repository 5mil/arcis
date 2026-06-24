//! rules.zig — Arcis naming phoneme tables and rank hierarchy
//! Phase 13 — expanded: Akkadian, Hebrew, Celtic, Egyptian fully implemented

const std = @import("std");

pub const Tradition = enum {
    greek, latin, sumerian, arabic, norse, sanskrit,
    akkadian, hebrew, celtic, egyptian,
};

pub const Rank = enum {
    initiate, adept, scholar, sage, archon, sovereign,

    pub fn suffix(self: Rank) []const u8 {
        return switch (self) {
            .initiate  => "",
            .adept     => "-vel",
            .scholar   => "-keth",
            .sage      => "-oran",
            .archon    => "-arxis",
            .sovereign => "-solun",
        };
    }
};

pub const PhonemeTable = struct {
    onsets:  []const []const u8,
    nuclei:  []const []const u8,
    codas:   []const []const u8,
};

const greek = PhonemeTable{
    .onsets = &.{ "Al", "Mn", "Ph", "Th", "Kr", "Ly", "Ps", "Xe", "Rh", "Gl" },
    .nuclei = &.{ "ei", "ao", "eu", "eo", "ia", "oi", "ae", "ou" },
    .codas  = &.{ "s",  "n",  "x",  "r",  "th", "k",  "p",  "m"  },
};

const latin = PhonemeTable{
    .onsets = &.{ "Au", "Cl", "Fl", "Gr", "Pr", "Sc", "St", "Tr", "Vi", "Qu" },
    .nuclei = &.{ "a",  "e",  "i",  "o",  "u",  "ae", "au", "oe" },
    .codas  = &.{ "us", "um", "ix", "or", "is", "as", "ex", "ax" },
};

const sumerian = PhonemeTable{
    .onsets = &.{ "En", "An", "Ki", "Ur", "Du", "In", "Na", "Zu", "Gi", "Lu" },
    .nuclei = &.{ "a",  "i",  "u",  "e",  "ia", "ul", "am" },
    .codas  = &.{ "gal","nun","kur","lil","sar","tur","bar","du"  },
};

const arabic = PhonemeTable{
    .onsets = &.{ "Abd","Ali","Has","Kal","Nas","Qad","Tar","Zah","Mal","Sal" },
    .nuclei = &.{ "al", "ar", "im", "an", "ud", "ir", "um" },
    .codas  = &.{ "din","oud","een","zan","wan","oom","aan","bir" },
};

const norse = PhonemeTable{
    .onsets = &.{ "Ulf","Bjor","Sig","Thor","Ran","Heid","Val","Arn","Gun","Skar" },
    .nuclei = &.{ "ar", "ir", "or", "ur", "ei", "au", "ey" },
    .codas  = &.{ "inn","ulf","kel","mar","vik","gar","nar","bor" },
};

const sanskrit = PhonemeTable{
    .onsets = &.{ "Dha","Bra","Sri","Kri","Var","Man","Sam","Jna","Pra","Cha" },
    .nuclei = &.{ "a",  "i",  "u",  "ai", "au", "ri", "aa" },
    .codas  = &.{ "ma", "ra", "na", "va", "ta", "ka", "la", "sa" },
};

// Phase 13 — Akkadian
const akkadian = PhonemeTable{
    .onsets = &.{ "Ash","Bel","Ish","Nab","Ner","Sha","Sin","Tam","Zer","Mar" },
    .nuclei = &.{ "a",  "u",  "i",  "an", "ar", "um", "al" },
    .codas  = &.{ "gal","dum","bit","ruk","nun","sar","kin","abu" },
};

// Phase 13 — Hebrew
const hebrew = PhonemeTable{
    .onsets = &.{ "El", "Gad","Bar","Sha","Yal","Uri","Avi","Ben","Ner","Ezi" },
    .nuclei = &.{ "a",  "e",  "i",  "o",  "ai", "ei", "av" },
    .codas  = &.{ "el", "ah", "on", "am", "im", "al", "or", "en" },
};

// Phase 13 — Celtic
const celtic = PhonemeTable{
    .onsets = &.{ "Bri","Cai","Dun","Eir","Fer","Gal","Mor","Nia","Tre","Wyn" },
    .nuclei = &.{ "ae", "ei", "ou", "ia", "oi", "an", "en" },
    .codas  = &.{ "dh", "th", "nn", "rn", "rd", "gh", "ch", "wr" },
};

// Phase 13 — Egyptian
const egyptian = PhonemeTable{
    .onsets = &.{ "Akh","Hor","Imo","Kha","Men","Nef","Ptah","Ra","Set","Tha" },
    .nuclei = &.{ "a",  "u",  "em", "en", "er", "et", "iu"  },
    .codas  = &.{ "hotep","mose","nkh","aten","ra","amon","sis","mes" },
};

pub fn tableFor(tradition: Tradition) PhonemeTable {
    return switch (tradition) {
        .greek    => greek,
        .latin    => latin,
        .sumerian => sumerian,
        .arabic   => arabic,
        .norse    => norse,
        .sanskrit => sanskrit,
        .akkadian => akkadian,
        .hebrew   => hebrew,
        .celtic   => celtic,
        .egyptian => egyptian,
    };
}

/// Generate a raw name string into `buf`. Returns the written slice.
/// seed is used as a simple index offset; caller should vary it to avoid collisions.
pub fn generateName(buf: []u8, tradition: Tradition, rank: Rank, seed: u64) []const u8 {
    const t = tableFor(tradition);
    const onset  = t.onsets[seed               % t.onsets.len];
    const nucleus = t.nuclei[(seed >> 3)        % t.nuclei.len];
    const coda    = t.codas[(seed >> 6)         % t.codas.len];
    const sfx     = rank.suffix();
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{ onset, nucleus, coda, sfx })
        catch buf[0..0];
}
