// mayhem/db_fuzzer.cc - upstream's fuzz/db_fuzzer.cc with the DB path, the input guard and one UB fixed.
//
// DB path: upstream keeps the DB at the fixed path /tmp/testdb. Mayhem runs several fuzzer/triage processes in
// the same container at once, so they shared it, deleted each other's files with DestroyDB, and a process
// that lost the lock race got Open != ok and returned without doing any work. Here each process uses its own
// directory, $TMPDIR/db_fuzzer_test.<pid> (TMPDIR defaults to /tmp), and LLVMFuzzerInitialize removes a
// stale one left by an earlier process with the same pid. Each input still opens the DB and destroys it at
// the end, exactly as upstream does.
//
// Also: an empty input returns before data[0] is read (upstream reads it unchecked); the first-Open failure
// path destroys the directory before returning; and the column-family handle is destroyed only if
// CreateColumnFamily succeeded (upstream passes an uninitialised handle when it fails). The operations and
// their arguments are otherwise unchanged.
//  Copyright (c) Meta Platforms, Inc. and affiliates.
//
//  This source code is licensed under both the GPLv2 (found in the
//  COPYING file in the root directory) and Apache 2.0 License
//  (found in the LICENSE.Apache file in the root directory).

#include <fuzzer/FuzzedDataProvider.h>
#include <unistd.h>

#include <cstdlib>
#include <filesystem>
#include <string>
#include <system_error>

#include "rocksdb/db.h"

enum OperationType {
  kPut,
  kGet,
  kDelete,
  kGetProperty,
  kIterator,
  kSnapshot,
  kOpenClose,
  kColumn,
  kCompactRange,
  kSeekForPrev,
  OP_COUNT
};

static const char* DbPath() {
  static const std::string path = [] {
    const char* tmp = getenv("TMPDIR");
    std::string dir = (tmp && tmp[0] != '\0') ? tmp : "/tmp";
    return dir + "/db_fuzzer_test." + std::to_string(getpid());
  }();
  return path.c_str();
}

extern "C" int LLVMFuzzerInitialize(int*, char***) {
  std::error_code ec;
  std::filesystem::remove_all(DbPath(), ec);
  return 0;
}

// Fuzzes DB operations by doing interpretations on the data. Both the
// sequence of API calls to be called on the DB as well as the arguments
// to each of these APIs are interpreted by way of the data buffer.
// The operations that the fuzzer supports are given by the OperationType
// enum. The goal is to capture sanitizer bugs, so the code should be
// compiled with a given sanitizer (ASan, UBSan, MSan).
extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size == 0) {
    return 0;
  }
  const char* db_path = DbPath();
  std::unique_ptr<ROCKSDB_NAMESPACE::DB> db;
  ROCKSDB_NAMESPACE::Options options;
  ROCKSDB_NAMESPACE::Status status;
  options.create_if_missing = true;
  status = ROCKSDB_NAMESPACE::DB::Open(options, db_path, &db);
  if (!status.ok()) {
    ROCKSDB_NAMESPACE::DestroyDB(db_path, options);
    return 0;
  }
  FuzzedDataProvider fuzzed_data(data, size);

  // perform a sequence of calls on our db instance
  int max_iter = static_cast<int>(data[0]);
  for (int i = 0; i < max_iter && i < size; i++) {
    OperationType op = static_cast<OperationType>(data[i] % OP_COUNT);

    switch (op) {
      case kPut: {
        std::string key = fuzzed_data.ConsumeRandomLengthString();
        std::string val = fuzzed_data.ConsumeRandomLengthString();
        db->Put(ROCKSDB_NAMESPACE::WriteOptions(), key, val);
        break;
      }
      case kGet: {
        std::string key = fuzzed_data.ConsumeRandomLengthString();
        std::string value;
        db->Get(ROCKSDB_NAMESPACE::ReadOptions(), key, &value);
        break;
      }
      case kDelete: {
        std::string key = fuzzed_data.ConsumeRandomLengthString();
        db->Delete(ROCKSDB_NAMESPACE::WriteOptions(), key);
        break;
      }
      case kGetProperty: {
        std::string prop;
        std::string property_name = fuzzed_data.ConsumeRandomLengthString();
        db->GetProperty(property_name, &prop);
        break;
      }
      case kIterator: {
        ROCKSDB_NAMESPACE::Iterator* it =
            db->NewIterator(ROCKSDB_NAMESPACE::ReadOptions());
        for (it->SeekToFirst(); it->Valid(); it->Next()) {
        }
        delete it;
        break;
      }
      case kSnapshot: {
        ROCKSDB_NAMESPACE::ReadOptions snapshot_options;
        snapshot_options.snapshot = db->GetSnapshot();
        ROCKSDB_NAMESPACE::Iterator* it = db->NewIterator(snapshot_options);
        db->ReleaseSnapshot(snapshot_options.snapshot);
        delete it;
        break;
      }
      case kOpenClose: {
        db->Close();
        db.reset();
        status = ROCKSDB_NAMESPACE::DB::Open(options, db_path, &db);
        if (!status.ok()) {
          ROCKSDB_NAMESPACE::DestroyDB(db_path, options);
          return 0;
        }

        break;
      }
      case kColumn: {
        ROCKSDB_NAMESPACE::ColumnFamilyHandle* cf = nullptr;
        ROCKSDB_NAMESPACE::Status s;
        s = db->CreateColumnFamily(ROCKSDB_NAMESPACE::ColumnFamilyOptions(),
                                   "new_cf", &cf);
        if (s.ok()) {
          s = db->DestroyColumnFamilyHandle(cf);
        }
        db->Close();
        db.reset();

        // open DB with two column families
        std::vector<ROCKSDB_NAMESPACE::ColumnFamilyDescriptor> column_families;
        // have to open default column family
        column_families.push_back(ROCKSDB_NAMESPACE::ColumnFamilyDescriptor(
            ROCKSDB_NAMESPACE::kDefaultColumnFamilyName,
            ROCKSDB_NAMESPACE::ColumnFamilyOptions()));
        // open the new one, too
        column_families.push_back(ROCKSDB_NAMESPACE::ColumnFamilyDescriptor(
            "new_cf", ROCKSDB_NAMESPACE::ColumnFamilyOptions()));
        std::vector<ROCKSDB_NAMESPACE::ColumnFamilyHandle*> handles;
        s = ROCKSDB_NAMESPACE::DB::Open(ROCKSDB_NAMESPACE::DBOptions(), db_path,
                                        column_families, &handles, &db);

        if (s.ok()) {
          std::string key1 = fuzzed_data.ConsumeRandomLengthString();
          std::string val1 = fuzzed_data.ConsumeRandomLengthString();
          std::string key2 = fuzzed_data.ConsumeRandomLengthString();
          s = db->Put(ROCKSDB_NAMESPACE::WriteOptions(), handles[1], key1,
                      val1);
          std::string value;
          s = db->Get(ROCKSDB_NAMESPACE::ReadOptions(), handles[1], key2,
                      &value);
          s = db->DropColumnFamily(handles[1]);
          for (auto handle : handles) {
            s = db->DestroyColumnFamilyHandle(handle);
          }
        } else {
          status = ROCKSDB_NAMESPACE::DB::Open(options, db_path, &db);
          if (!status.ok()) {
            // At this point there is no saving to do. So we exit
            ROCKSDB_NAMESPACE::DestroyDB(db_path, ROCKSDB_NAMESPACE::Options());
            return 0;
          }
        }
        break;
      }
      case kCompactRange: {
        std::string slice_start = fuzzed_data.ConsumeRandomLengthString();
        std::string slice_end = fuzzed_data.ConsumeRandomLengthString();

        ROCKSDB_NAMESPACE::Slice begin(slice_start);
        ROCKSDB_NAMESPACE::Slice end(slice_end);
        ROCKSDB_NAMESPACE::CompactRangeOptions options;
        ROCKSDB_NAMESPACE::Status s = db->CompactRange(options, &begin, &end);
        break;
      }
      case kSeekForPrev: {
        std::string key = fuzzed_data.ConsumeRandomLengthString();
        auto iter = db->NewIterator(ROCKSDB_NAMESPACE::ReadOptions());
        iter->SeekForPrev(key);
        delete iter;
        break;
      }
      case OP_COUNT:
        break;
    }
  }

  // Cleanup DB
  db->Close();
  db.reset();
  ROCKSDB_NAMESPACE::DestroyDB(db_path, options);
  return 0;
}
