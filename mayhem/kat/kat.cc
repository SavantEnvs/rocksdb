// Known-answer probe over the public RocksDB API. mayhem/test.sh asserts this program's exact stdout,
// so a program turned into a no-op (empty output) fails the oracle.
#include <cstdlib>
#include <iostream>
#include <memory>
#include <string>
#include <unistd.h>

#include "rocksdb/db.h"
#include "rocksdb/options.h"
#include "rocksdb/sst_file_reader.h"
#include "rocksdb/sst_file_writer.h"

using namespace ROCKSDB_NAMESPACE;

static void must(const Status& s, const char* what) {
  if (!s.ok()) {
    std::cerr << what << ": " << s.ToString() << std::endl;
    std::exit(2);
  }
}

static std::string dump(DB* db) {
  std::unique_ptr<Iterator> it(db->NewIterator(ReadOptions()));
  std::string out;
  for (it->SeekToFirst(); it->Valid(); it->Next()) {
    out += it->key().ToString() + "=" + it->value().ToString() + ";";
  }
  must(it->status(), "iterate");
  return out;
}

int main() {
  char tmpl[] = "/tmp/rocksdb-kat-XXXXXX";
  if (!mkdtemp(tmpl)) return 2;
  std::string dir = tmpl;
  Options options;
  options.create_if_missing = true;

  {
    std::unique_ptr<DB> db;
    must(DB::Open(options, dir + "/db", &db), "open");
    must(db->Put(WriteOptions(), "a", "1"), "put a");
    must(db->Put(WriteOptions(), "b", "2"), "put b");
    must(db->Put(WriteOptions(), "c", "3"), "put c");
    must(db->Delete(WriteOptions(), "b"), "delete b");
    std::string v;
    must(db->Get(ReadOptions(), "c", &v), "get c");
    std::cout << "get c: " << v << std::endl;
    Status s = db->Get(ReadOptions(), "b", &v);
    std::cout << "get b: " << (s.IsNotFound() ? "not found" : "found") << std::endl;
    std::cout << "iter: " << dump(db.get()) << std::endl;
    must(db->Flush(FlushOptions()), "flush");
    must(db->Close(), "close");
  }
  {
    std::unique_ptr<DB> db;
    must(DB::Open(options, dir + "/db", &db), "reopen");
    std::cout << "reopened: " << dump(db.get()) << std::endl;
    must(db->Close(), "close2");
  }
  {
    std::string sst = dir + "/kat.sst";
    SstFileWriter writer(EnvOptions(), options);
    must(writer.Open(sst), "sst open");
    must(writer.Put("k1", "v1"), "sst put 1");
    must(writer.Put("k2", "v2"), "sst put 2");
    must(writer.Put("k3", "v3"), "sst put 3");
    ExternalSstFileInfo info;
    must(writer.Finish(&info), "sst finish");
    std::cout << "sst entries: " << info.num_entries << " smallest=" << info.smallest_key
              << " largest=" << info.largest_key << std::endl;
    SstFileReader reader(options);
    must(reader.Open(sst), "sst reader open");
    must(reader.VerifyChecksum(), "sst verify");
    std::unique_ptr<Iterator> it(reader.NewIterator(ReadOptions()));
    std::string out;
    for (it->SeekToFirst(); it->Valid(); it->Next())
      out += it->key().ToString() + "=" + it->value().ToString() + ";";
    std::cout << "sst iter: " << out << std::endl;
  }
  std::string cmd = "rm -rf " + dir;
  if (std::system(cmd.c_str()) != 0) return 2;
  return 0;
}
