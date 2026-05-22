// test_helpers.cpp — unit tests for the vendored helpers' PURE parsers
// (Doc 11). These test the parsing logic against fixture strings, so they
// are deterministic and need no live cgroup/PSI filesystem. The live
// readers are exercised by running the binary under real caps in demo.sh;
// the logic is pinned here.

#include <gtest/gtest.h>

#include "cgroup_helper.h"
#include "psi_reader.h"

// ── cgroup cpu.max (v2) ───────────────────────────────────────────────
TEST(CgroupCpuMax, QuotaOverPeriod) {
    auto v = cgroup_helper::parse_cpu_max("150000 100000");
    ASSERT_TRUE(v.has_value());
    EXPECT_DOUBLE_EQ(*v, 1.5);
}
TEST(CgroupCpuMax, OneCore) {
    EXPECT_DOUBLE_EQ(*cgroup_helper::parse_cpu_max("100000 100000"), 1.0);
}
TEST(CgroupCpuMax, HalfCore) {
    EXPECT_DOUBLE_EQ(*cgroup_helper::parse_cpu_max("50000 100000"), 0.5);
}
TEST(CgroupCpuMax, MaxIsUnconstrained) {
    EXPECT_FALSE(cgroup_helper::parse_cpu_max("max 100000").has_value());
}
TEST(CgroupCpuMax, Malformed) {
    EXPECT_FALSE(cgroup_helper::parse_cpu_max("").has_value());
    EXPECT_FALSE(cgroup_helper::parse_cpu_max("garbage").has_value());
    EXPECT_FALSE(cgroup_helper::parse_cpu_max("100000 0").has_value());
}

// ── cgroup cpu (v1) ───────────────────────────────────────────────────
TEST(CgroupCpuV1, QuotaOverPeriod) {
    EXPECT_DOUBLE_EQ(*cgroup_helper::parse_cpu_v1(200000, 100000), 2.0);
}
TEST(CgroupCpuV1, UnlimitedIsNullopt) {
    EXPECT_FALSE(cgroup_helper::parse_cpu_v1(-1, 100000).has_value());
}

// ── cgroup memory.max ─────────────────────────────────────────────────
TEST(CgroupMemMax, ByteCount) {
    auto v = cgroup_helper::parse_mem_max("268435456");
    ASSERT_TRUE(v.has_value());
    EXPECT_EQ(*v, 268435456u);  // 256 MiB
}
TEST(CgroupMemMax, TrailingNewline) {
    EXPECT_EQ(*cgroup_helper::parse_mem_max("268435456\n"), 268435456u);
}
TEST(CgroupMemMax, MaxIsUnbounded) {
    EXPECT_FALSE(cgroup_helper::parse_mem_max("max").has_value());
}
TEST(CgroupMemMax, HugeSentinelIsUnbounded) {
    // cgroup v1 "unlimited" sentinel is enormous; treat as unbounded.
    EXPECT_FALSE(cgroup_helper::parse_mem_max("9223372036854771712").has_value());
}

// ── PSI parsing ───────────────────────────────────────────────────────
TEST(PsiParse, SomeLine) {
    const char* psi =
        "some avg10=1.50 avg60=0.30 avg300=0.05 total=1234567\n"
        "full avg10=0.10 avg60=0.02 avg300=0.00 total=234567\n";
    auto p = psi_reader::parse_some(psi);
    ASSERT_TRUE(p.has_value());
    EXPECT_DOUBLE_EQ(p->avg10, 1.50);
    EXPECT_DOUBLE_EQ(p->avg60, 0.30);
    EXPECT_DOUBLE_EQ(p->avg300, 0.05);
    EXPECT_DOUBLE_EQ(p->total, 1234567.0);
}
TEST(PsiParse, FullLine) {
    const char* psi =
        "some avg10=1.50 avg60=0.30 avg300=0.05 total=1234567\n"
        "full avg10=0.10 avg60=0.02 avg300=0.00 total=234567\n";
    auto p = psi_reader::parse_full(psi);
    ASSERT_TRUE(p.has_value());
    EXPECT_DOUBLE_EQ(p->avg10, 0.10);
    EXPECT_DOUBLE_EQ(p->total, 234567.0);
}
TEST(PsiParse, CpuHasNoFullLine) {
    // /proc/pressure/cpu emits only a "some" line; parse_full -> nullopt.
    const char* psi = "some avg10=0.00 avg60=0.00 avg300=0.00 total=42\n";
    EXPECT_TRUE(psi_reader::parse_some(psi).has_value());
    EXPECT_FALSE(psi_reader::parse_full(psi).has_value());
}
TEST(PsiParse, Empty) {
    EXPECT_FALSE(psi_reader::parse_some("").has_value());
}
