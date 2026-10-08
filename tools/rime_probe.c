/*
 * probe.c —— 无 GUI 的 librime 测试器（flow_engine 同步测试用）
 *
 * 编译：
 *   cc probe.c -I/tmp/librime-src/src -o probe /usr/lib64/librime.so.1 \
 *      -Wl,-rpath,/usr/lib64
 *
 * 用法：
 *   ./probe <user_data_dir> [--sync] [keys] [select_index]
 *     keys 支持 ^=空格 ~=退格 \t=Tab \n=回车，其它字符原样
 *     --sync：跑完 keys 后调用 RimeSyncUserData（无 keys 则只同步）
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "rime_api.h"

static RimeApi* api;

static void drain_candidates(RimeSessionId s);

static void show_candidates(RimeSessionId s) {
  const char* input = api->get_input(s);
  RimeContext ctx;
  memset(&ctx, 0, sizeof(ctx));
  RIME_STRUCT_INIT(RimeContext, ctx);
  if (api->get_context(s, &ctx)) {
    printf("  input=[%s] preedit=[%s]\n", input ? input : "",
           ctx.composition.preedit ? ctx.composition.preedit : "");
    api->free_context(&ctx);
  } else {
    printf("  input=[%s]\n", input ? input : "");
  }
  RimeCandidateListIterator it;
  memset(&it, 0, sizeof(it));
  if (!api->candidate_list_begin(s, &it)) {
    printf("    (no candidates)\n");
    return;
  }
  int n = 0;
  while (api->candidate_list_next(&it) && n < 12) {
    printf("    %2d. %-14s %s\n", n + 1, it.candidate.text,
           it.candidate.comment ? it.candidate.comment : "");
    ++n;
  }
  api->candidate_list_end(&it);
}

static void print_commit(RimeSessionId s) {
  RimeCommit commit;
  memset(&commit, 0, sizeof(commit));
  if (api->get_commit(s, &commit)) {
    printf("    commit: %s\n", commit.text);
    api->free_commit(&commit);
  }
}

static int keycode_of(char c) {
  if (c == '^') return ' ';
  if (c == '~') return 0xff08;   /* BackSpace */
  return (unsigned char)c;
}

/* 支持 \t \n \~ \^ 转义；普通字符原样 */
static int next_keycode(const char** p) {
  char c = **p;
  if (c == '\\' && (*p)[1]) {
    ++(*p);
    switch (**p) {
      case 't': return 0xff09;
      case 'n': return 0xff0d;
      case '~': return 0xff08;
      case '^': return ' ';
      default: return (unsigned char)**p;
    }
  }
  return keycode_of(c);
}

static void run_case(const char* keys, int select_index) {
  RimeSessionId s = api->create_session();
  if (!s) {
    printf("create_session failed\n");
    return;
  }
  printf("keys \"%s\":\n", keys);
  for (const char* p = keys; *p; ++p) {
    api->process_key(s, next_keycode(&p), 0);
    drain_candidates(s);   /* 模拟 UI 每键拉一次候选 */
  }
  show_candidates(s);
  if (select_index > 0) {
    api->process_key(s, '0' + select_index, 0);
    print_commit(s);
  } else {
    print_commit(s);
  }
  api->destroy_session(s);
}

static double now_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void drain_candidates(RimeSessionId s) {
  RimeCandidateListIterator it;
  memset(&it, 0, sizeof(it));
  if (api->candidate_list_begin(s, &it)) {
    while (api->candidate_list_next(&it)) {
    }
    api->candidate_list_end(&it);
  }
}

static void bench(int rounds) {
  static const char* cases[] = {
      "wum",          "wumk",        "wumkuy",       "rkg;n",
      "uy;gr",        "sufy",        "qyprk",        "rkgj;ynp",
      "wumku;jgurk",  "wumkuy;jgurk", NULL};
  RimeSessionId s = api->create_session();
  api->select_schema(s, "xkjd27c_flow");
  int queries = 0;
  for (int warm = 0; warm < 2; ++warm) {
    double t0 = now_seconds();
    queries = 0;
    for (int i = 0; i < rounds; ++i) {
      for (int j = 0; cases[j]; ++j) {
        api->clear_composition(s);
        for (const char* p = cases[j]; *p; ++p) {
          api->process_key(s, (unsigned char)*p, 0);
        }
        drain_candidates(s);
        ++queries;
      }
    }
    double dt = now_seconds() - t0;
    if (warm > 0) {
      printf("bench: %d queries in %.3f s (%.3f ms/query)\n", queries, dt,
             dt * 1000 / queries);
    }
  }
  api->destroy_session(s);
}

int main(int argc, char** argv) {
  const char* user_dir = (argc > 1) ? argv[1] : "/tmp/rime_flow_test";
  int do_sync = 0;
  const char* keys = NULL;
  int select_index = 0;
  int do_bench = 0;
  int bench_rounds = 200;

  for (int i = 2; i < argc; ++i) {
    if (strcmp(argv[i], "--sync") == 0) {
      do_sync = 1;
    } else if (strcmp(argv[i], "--bench") == 0) {
      do_bench = 1;
      if (i + 1 < argc) bench_rounds = atoi(argv[++i]);
    } else if (!keys) {
      keys = argv[i];
    } else {
      select_index = atoi(argv[i]);
    }
  }

  api = rime_get_api();
  if (!api) {
    fprintf(stderr, "rime_get_api() returned NULL\n");
    return 1;
  }

  RimeTraits traits;
  memset(&traits, 0, sizeof(traits));
  RIME_STRUCT_INIT(RimeTraits, traits);
  traits.shared_data_dir = "/usr/share/rime-data";
  traits.user_data_dir = user_dir;
  traits.distribution_name = "Rime";
  traits.distribution_code_name = "rime_probe";
  traits.distribution_version = "1.16.1";
  traits.app_name = "rime.probe";
  traits.log_dir = "/tmp";

  api->setup(&traits);
  api->initialize(&traits);
  if (api->start_maintenance(True)) {
    api->join_maintenance_thread();
  }

  {
    RimeSessionId s = api->create_session();
    api->select_schema(s, "xkjd27c_flow");
    api->destroy_session(s);
  }

  if (do_bench) {
    bench(bench_rounds);
    api->finalize();
    return 0;
  }

  if (keys) {
    run_case(keys, select_index);
  }

  if (do_sync) {
    printf("SYNC...\n");
    api->sync_user_data();
    api->join_maintenance_thread();
    printf("SYNC_OK\n");
  }

  if (!keys && !do_sync) {
    run_case("wum", 0);
    run_case("wwukmf", 0);
    run_case("wumk", 0);
    run_case("wumkuy", 0);
    run_case("rkg;n", 0);
    run_case("rkgj;ynp", 0);
    run_case(";gr", 0);
    run_case("uy;gr", 0);
    run_case("wumk", 1);
    run_case("wumk", 0);
  }

  api->finalize();
  return 0;
}
