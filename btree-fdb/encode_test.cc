// Property tests for the order-preserving encoding stated in
// `spec/BtreeReplacement.lean`. Each theorem the Lean file names as an
// obligation is a `PROP_CHECK` here, paired with a rule-2 planted-wrong
// control per CLAUDE.md's "How Work Is Verified" rule 2.
//
// SPDX-License-Identifier: Apache-2.0

extern "C" {
#include "encode.h"
}

#include "witness/doctest.h"

#include <cstdint>
#include <cstring>
#include <string>
#include <tuple>
#include <vector>

namespace {

// Full 64-bit range, so a control that fails only for values with a set high
// bit finds one at rung 0.
int64_t gen_int64_wide(witness::RNG &rng, const witness::Level &) {
	uint64_t hi = rng.uint_range(0, UINT32_MAX);
	uint64_t lo = rng.uint_range(0, UINT32_MAX);
	return (int64_t)((hi << 32) | lo);
}

// UTF-8-ish bytes, bounded so a rung levels off in reasonable time.
witness::Generator<std::vector<uint8_t>> gen_bytes(size_t max_len) {
	return [max_len](witness::RNG &rng, const witness::Level &lvl) {
		size_t cap = max_len < static_cast<size_t>(lvl.fin_bound)
			? max_len : static_cast<size_t>(lvl.fin_bound);
		uint32_t n = rng.uint_range(0, static_cast<uint32_t>(cap));
		std::vector<uint8_t> v(n);
		for (uint32_t i = 0; i < n; ++i)
			v[i] = static_cast<uint8_t>(rng.uint_range(0, 255));
		return v;
	};
}

std::string encode_int_str(int64_t n) {
	uint8_t buf[WEFT_ENCODE_INT_BYTES];
	int m = weft_encode_int(buf, n);
	return std::string(reinterpret_cast<char *>(buf), static_cast<size_t>(m));
}

std::string encode_text_str(const std::vector<uint8_t> &bytes) {
	std::vector<uint8_t> buf(1 + bytes.size());
	int m = weft_encode_text(buf.data(), bytes.data(), bytes.size());
	return std::string(reinterpret_cast<char *>(buf.data()), static_cast<size_t>(m));
}

}  // namespace

// ── The load-bearing theorem: encode_orderPreserving ──────────────────────────
//
// The Lean file states this across all `Int` and all `List UInt8`. The property
// tests below witness it in the concrete C encoding on random pairs of each.

using Int64Pair = std::tuple<int64_t, int64_t>;

TEST_CASE("[encode] int PK: memcmp order equals signed integer order") {
	witness::Generator<Int64Pair> gen = witness::gen_tuple<int64_t, int64_t>(
		&gen_int64_wide, &gen_int64_wide);
	std::function<bool(const Int64Pair &)> pred = [](const Int64Pair &p) {
		int64_t a = std::get<0>(p);
		int64_t b = std::get<1>(p);
		std::string ka = encode_int_str(a);
		std::string kb = encode_int_str(b);
		if (a < b) return ka < kb;
		if (a > b) return ka > kb;
		return ka == kb;
	};
	PROP_CHECK(Int64Pair, "weft_encode_int preserves signed order under memcmp", gen, pred);
}

using BytesPair = std::tuple<std::vector<uint8_t>, std::vector<uint8_t>>;

TEST_CASE("[encode] text PK: memcmp order equals input byte-lex order") {
	witness::Generator<BytesPair> gen =
		witness::gen_tuple<std::vector<uint8_t>, std::vector<uint8_t>>(
			gen_bytes(32), gen_bytes(32));
	std::function<bool(const BytesPair &)> pred = [](const BytesPair &p) {
		const auto &a = std::get<0>(p);
		const auto &b = std::get<1>(p);
		std::string ka = encode_text_str(a);
		std::string kb = encode_text_str(b);
		// Reference: byte-lex on the input bytes.
		auto aref = std::string(reinterpret_cast<const char *>(a.data()), a.size());
		auto bref = std::string(reinterpret_cast<const char *>(b.data()), b.size());
		if (aref < bref) return ka < kb;
		if (aref > bref) return ka > kb;
		return ka == kb;
	};
	PROP_CHECK(BytesPair, "weft_encode_text preserves byte-lex order under memcmp", gen, pred);
}

using MixedPair = std::tuple<int64_t, std::vector<uint8_t>>;

TEST_CASE("[encode] cross-branch: every int PK sorts before every text PK") {
	witness::Generator<MixedPair> gen =
		witness::gen_tuple<int64_t, std::vector<uint8_t>>(&gen_int64_wide, gen_bytes(32));
	std::function<bool(const MixedPair &)> pred = [](const MixedPair &p) {
		std::string ki = encode_int_str(std::get<0>(p));
		std::string kt = encode_text_str(std::get<1>(p));
		return ki < kt;
	};
	PROP_CHECK(MixedPair, "int-tag byte 0x01 sorts before text-tag byte 0x02", gen, pred);
}

// ── Rule-2 controls (per CLAUDE.md "How Work Is Verified" rule 2) ─────────────
//
// Each false variant must be FOUND at rung 0. A silent skip reads as a pass;
// a variant that quietly *matches* the correct encoding reads as a pass too.
// So each control differs from the correct encoding in one specific way, and
// the wide generators above sample values that expose that difference.

TEST_CASE("[encode] rule-2 control: little-endian int encoding loses signed order") {
	// The wrong encoder writes the bytes little-endian instead of big-endian.
	// A pair whose big-endian and little-endian orderings disagree exists as
	// soon as the top byte differs; gen_int64_wide covers that space.
	witness::Generator<Int64Pair> gen = witness::gen_tuple<int64_t, int64_t>(
		&gen_int64_wide, &gen_int64_wide);
	std::function<bool(const Int64Pair &)> pred = [](const Int64Pair &p) {
		int64_t a = std::get<0>(p);
		int64_t b = std::get<1>(p);
		auto le_key = [](int64_t n) {
			uint64_t u = ((uint64_t)n) ^ ((uint64_t)1 << 63);
			uint8_t buf[9];
			buf[0] = 0x01;
			for (int i = 0; i < 8; ++i) buf[1 + i] = (uint8_t)((u >> (8 * i)) & 0xff);
			return std::string(reinterpret_cast<char *>(buf), 9);
		};
		std::string ka = le_key(a);
		std::string kb = le_key(b);
		if (a < b) return ka < kb;
		if (a > b) return ka > kb;
		return ka == kb;
	};
	witness::Trial t = witness::resolve<Int64Pair>(
		"little-endian int encoding preserves signed order", gen, pred);
	INFO(t.message);
	CHECK(t.outcome == witness::Outcome::FOUND);
}

TEST_CASE("[encode] rule-2 control: unflipped-sign int encoding loses negative order") {
	// The wrong encoder is big-endian but does not flip the sign bit. Then a
	// negative int has its top byte set (0x80+) and sorts *after* a positive
	// int, which reverses signed order for any negative-vs-positive pair.
	witness::Generator<Int64Pair> gen = witness::gen_tuple<int64_t, int64_t>(
		&gen_int64_wide, &gen_int64_wide);
	std::function<bool(const Int64Pair &)> pred = [](const Int64Pair &p) {
		int64_t a = std::get<0>(p);
		int64_t b = std::get<1>(p);
		auto raw_be = [](int64_t n) {
			uint64_t u = (uint64_t)n;
			uint8_t buf[9];
			buf[0] = 0x01;
			for (int i = 0; i < 8; ++i) buf[1 + i] = (uint8_t)((u >> (8 * (7 - i))) & 0xff);
			return std::string(reinterpret_cast<char *>(buf), 9);
		};
		std::string ka = raw_be(a);
		std::string kb = raw_be(b);
		if (a < b) return ka < kb;
		if (a > b) return ka > kb;
		return ka == kb;
	};
	witness::Trial t = witness::resolve<Int64Pair>(
		"raw big-endian int encoding preserves signed order", gen, pred);
	INFO(t.message);
	CHECK(t.outcome == witness::Outcome::FOUND);
}

TEST_CASE("[encode] rule-2 control: swapped tags reverse cross-branch order") {
	// int-tag 0x02 and text-tag 0x01 reverses cross-branch order: text-PK
	// keys would sort before int-PK keys, breaking the Lean spec's pkLt
	// convention.
	witness::Generator<MixedPair> gen =
		witness::gen_tuple<int64_t, std::vector<uint8_t>>(&gen_int64_wide, gen_bytes(32));
	std::function<bool(const MixedPair &)> pred = [](const MixedPair &p) {
		int64_t n = std::get<0>(p);
		const auto &bytes = std::get<1>(p);
		uint64_t u = ((uint64_t)n) ^ ((uint64_t)1 << 63);
		uint8_t ibuf[9];
		ibuf[0] = 0x02;   // swapped
		for (int i = 0; i < 8; ++i) ibuf[1 + i] = (uint8_t)((u >> (8 * (7 - i))) & 0xff);
		std::vector<uint8_t> tbuf(1 + bytes.size());
		tbuf[0] = 0x01;   // swapped
		if (!bytes.empty()) memcpy(tbuf.data() + 1, bytes.data(), bytes.size());
		std::string ki(reinterpret_cast<char *>(ibuf), 9);
		std::string kt(reinterpret_cast<char *>(tbuf.data()), tbuf.size());
		return ki < kt;
	};
	witness::Trial t = witness::resolve<MixedPair>(
		"swapped tags preserve int-before-text order", gen, pred);
	INFO(t.message);
	CHECK(t.outcome == witness::Outcome::FOUND);
}
