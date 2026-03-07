/*
* This file is part of the BSGS distribution (https://github.com/JeanLucPons/Kangaroo).
* Copyright (c) 2020 Jean Luc PONS.
*
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, version 3.
*
* This program is distributed in the hope that it will be useful, but
* WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program. If not, see <http://www.gnu.org/licenses/>.
*/

#include "Kangaroo.h"
#include <fstream>
#include "SECPK1/IntGroup.h"
#include "Timer.h"
#include <string.h>
#define _USE_MATH_DEFINES
#include <math.h>
#include <algorithm>
#ifndef WIN64
#include <pthread.h>
#include <sys/stat.h>
#endif

using namespace std;


// ----------------------------------------------------------------------------

int Kangaroo::FSeek(FILE* stream,uint64_t pos) {

#ifdef WIN64
  return _fseeki64(stream,pos,SEEK_SET);
#else
  return fseeko(stream,pos,SEEK_SET);
#endif

}

uint64_t Kangaroo::FTell(FILE* stream) {

#ifdef WIN64
  return (uint64_t)_ftelli64(stream);
#else
  return (uint64_t)ftello(stream);
#endif

}

bool Kangaroo::IsEmpty(std::string fileName) {

  FILE *pFile = fopen(fileName.c_str(),"r");
  if(pFile==NULL) {
    ::printf("OpenPart: Cannot open %s for reading\n",fileName.c_str());
    ::printf("%s\n",::strerror(errno));
    ::exit(0);
  }
  fseek(pFile,0,SEEK_END);
  uint32_t size = ftell(pFile);
  fclose(pFile);
  return size==0;

}

int Kangaroo::IsDir(string dirName) {

  bool isDir = 0;

#ifdef WIN64

  WIN32_FIND_DATA ffd;
  HANDLE hFind;

  hFind = FindFirstFile(dirName.c_str(),&ffd);
  if(hFind == INVALID_HANDLE_VALUE) {
    ::printf("%s not found\n",dirName.c_str());
    return -1;
  }
  isDir = (ffd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  FindClose(hFind);

#else

  struct stat buffer;
  if(stat(dirName.c_str(),&buffer) != 0) {
    ::printf("%s not found\n",dirName.c_str());
    return -1;
  }
  isDir = (buffer.st_mode & S_IFDIR) != 0;

#endif

  return isDir;

}

FILE *Kangaroo::ReadHeader(std::string fileName, uint32_t *version, int type) {

  FILE *f = fopen(fileName.c_str(),"rb");
  if(f == NULL) {
    ::printf("ReadHeader: Cannot open %s for reading\n",fileName.c_str());
    ::printf("%s\n",::strerror(errno));
    return NULL;
  }
  uint32_t head;
  uint32_t versionF;

  // Read header
  if(::fread(&head,sizeof(uint32_t),1,f) != 1) {
    ::printf("ReadHeader: Cannot read from %s\n",fileName.c_str());
    if(::feof(f)) {
      ::printf("Empty file\n");
    } else {
      ::printf("%s\n",::strerror(errno));
    }
    ::fclose(f);
    return NULL;
  }

  ::fread(&versionF,sizeof(uint32_t),1,f);
  if(version) *version = versionF;

  if(head!=type) {
    if(head==HEADK) {
      fread(&nbLoadedWalk,sizeof(uint64_t),1,f);
      ::printf("ReadHeader: %s is a kangaroo only file [2^%.2f kangaroos]\n",fileName.c_str(),log2((double)nbLoadedWalk));
    } if(head == HEADKS) {
      fread(&nbLoadedWalk,sizeof(uint64_t),1,f);
      ::printf("ReadHeader: %s is a compressed kangaroo only file [2^%.2f kangaroos]\n",fileName.c_str(),log2((double)nbLoadedWalk));
    } else if(head==HEADW) {
      ::printf("ReadHeader: %s is a work file, kangaroo only file expected\n",fileName.c_str());
    } else {
      ::printf("ReadHeader: %s Not a work file\n",fileName.c_str());
    }
    ::fclose(f);
    return NULL;
  }

  return f;

}

bool Kangaroo::LoadWork(string &fileName) {

  double t0 = Timer::get_tick();

  ::printf("Loading: %s\n",fileName.c_str());
  uint32_t version = 0;

  if(!clientMode) {

    fRead = ReadHeader(fileName,&version,HEADW);
    if(fRead == NULL)
      return false;

    keysToSearch.clear();
    Point key;

    // Read global param
    uint32_t dp;
    ::fread(&dp,sizeof(uint32_t),1,fRead);
    if(initDPSize < 0) initDPSize = dp;
    ::fread(&rangeStart.bits64,32,1,fRead); rangeStart.bits64[4] = 0;
    ::fread(&rangeEnd.bits64,32,1,fRead); rangeEnd.bits64[4] = 0;
    ::fread(&key.x.bits64,32,1,fRead); key.x.bits64[4] = 0;
    ::fread(&key.y.bits64,32,1,fRead); key.y.bits64[4] = 0;
    ::fread(&offsetCount,sizeof(uint64_t),1,fRead);
    ::fread(&offsetTime,sizeof(double),1,fRead);

    key.z.SetInt32(1);
    if(!secp->EC(key)) {
      ::printf("LoadWork: key does not lie on elliptic curve\n");
      return false;
    }

    keysToSearch.push_back(key);

    ::printf("Start:%s\n",rangeStart.GetBase16().c_str());
    ::printf("Stop :%s\n",rangeEnd.GetBase16().c_str());
    ::printf("Keys :%d\n",(int)keysToSearch.size());

    // Read hashTable
    hashTable.LoadTable(fRead);

  } else {

    // In client mode, config come from the server, file has only kangaroo
    fRead = ReadHeader(fileName,&version,HEADK);
    if(fRead == NULL)
      return false;

  }

  loadedWorkVersion = version;
  loadedWorkHasSymClass = (loadedWorkVersion >= 1);
  loadedWorkHasThreadMeta = false;
  loadedWorkThreadMeta.clear();

#ifdef USE_SYMMETRY
  if(loadedWorkVersion < GetMinReadableWorkFileVersion()) {
    ::printf("LoadWork: ERROR - workfile version %d uses 128-bit distance (incompatible with 192-bit format).\n",
             loadedWorkVersion);
    ::printf("LoadWork: Please discard this workfile and start a fresh run.\n");
    ::fclose(fRead);
    fRead = NULL;
    return false;
  }
#else
  if(loadedWorkVersion < GetMinReadableWorkFileVersion()) {
    ::printf("LoadWork: WARNING - legacy workfile version %d (no 192-bit distance upgrade).\n",
             loadedWorkVersion);
    ::printf("LoadWork: HashTable format may be incompatible. Discarding old workfile.\n");
    ::fclose(fRead);
    fRead = NULL;
    return false;
  }
#endif

  // Read number of walk
  fread(&nbLoadedWalk,sizeof(uint64_t),1,fRead);

  if(WorkFileHasThreadMeta(loadedWorkVersion) && !LoadThreadLayout(fRead)) {
    ::fclose(fRead);
    fRead = NULL;
    return false;
  }

#ifdef USE_SYMMETRY
  if(nbLoadedWalk > 0 && !loadedWorkHasSymClass) {
    ::printf("LoadWork: Warning legacy workfile has no symmetry class state, restoring with symClass=0\n");
  }
#endif

  double t1 = Timer::get_tick();

  ::printf("LoadWork: [HashTable %s] [%s]\n",hashTable.GetSizeInfo().c_str(),GetTimeStr(t1 - t0).c_str());

  return true;
}

// ----------------------------------------------------------------------------

WORK_THREAD_META Kangaroo::GetThreadMeta(const TH_PARAM &thread,bool gpuThread) const {

  WORK_THREAD_META meta;
  memset(&meta,0,sizeof(meta));
  meta.nbKangaroo = thread.nbKangaroo;

#ifdef WITHGPU
  if(gpuThread) {
    meta.flags = WORK_THREAD_META_GPU;
    meta.gridSizeX = (uint32_t)thread.gridSizeX;
    meta.gridSizeY = (uint32_t)thread.gridSizeY;
    meta.groupSize = (uint32_t)thread.groupSize;
  }
#else
  (void)gpuThread;
#endif

  return meta;

}

bool Kangaroo::IsThreadMetaCompatible(const WORK_THREAD_META &saved,const TH_PARAM &current,bool gpuThread) const {

  WORK_THREAD_META now = GetThreadMeta(current,gpuThread);
  return saved.flags == now.flags &&
         saved.gridSizeX == now.gridSizeX &&
         saved.gridSizeY == now.gridSizeY &&
         saved.groupSize == now.groupSize &&
         saved.nbKangaroo == now.nbKangaroo;

}

uint32_t Kangaroo::GetWalkerTypeForMeta(const WORK_THREAD_META &meta,uint64_t localIndex) const {

  if((meta.flags & WORK_THREAD_META_GPU) == 0U || meta.gridSizeY == 0U || meta.groupSize == 0U) {
    return (uint32_t)(localIndex & 1ULL);
  }

  uint64_t walkersPerBlock = (uint64_t)meta.gridSizeY * (uint64_t)meta.groupSize;
  if(walkersPerBlock == 0ULL) {
    return (uint32_t)(localIndex & 1ULL);
  }

  uint64_t rem = localIndex % walkersPerBlock;
  uint64_t t = rem % (uint64_t)meta.gridSizeY;
  return (uint32_t)(t & 1ULL);

}

bool Kangaroo::ClassifyKangarooType(const Int *px,const Int *py,const Int *d,uint32_t *type) {

  if(type == NULL) {
    return false;
  }

  (void)py;
  auto sameX = [&](const Point &p) -> bool {
    return p.x.bits64[0] == px->bits64[0] &&
           p.x.bits64[1] == px->bits64[1] &&
           p.x.bits64[2] == px->bits64[2] &&
           p.x.bits64[3] == px->bits64[3];
  };

  Int dist(*d);
  Point walk = secp->ComputePublicKey(&dist);
  if(sameX(walk)) {
    *type = TAME;
    return true;
  }

  Point wild = secp->AddDirect(keyToSearch,walk);
  if(sameX(wild)) {
    *type = WILD;
    return true;
  }

#ifdef USE_SYMMETRY
  Point wildAlt = secp->AddDirect(keyToSearchNeg,walk);
  if(sameX(wildAlt)) {
    *type = WILD;
    return true;
  }
#endif

  return false;

}

bool Kangaroo::SaveThreadLayout(FILE *f,TH_PARAM *threads,int nbThread) {

  uint32_t magic = WORK_THREAD_META_MAGIC;
  uint32_t threadCount = (threads != NULL && nbThread > 0) ? (uint32_t)nbThread : 0U;

  if(::fwrite(&magic,sizeof(uint32_t),1,f) != 1) return false;
  if(::fwrite(&threadCount,sizeof(uint32_t),1,f) != 1) return false;

  for(int i = 0; i < nbThread; i++) {
    bool gpuThread = (i >= nbCPUThread);
    WORK_THREAD_META meta = GetThreadMeta(threads[i],gpuThread);
    if(::fwrite(&meta.flags,sizeof(uint32_t),1,f) != 1) return false;
    if(::fwrite(&meta.gridSizeX,sizeof(uint32_t),1,f) != 1) return false;
    if(::fwrite(&meta.gridSizeY,sizeof(uint32_t),1,f) != 1) return false;
    if(::fwrite(&meta.groupSize,sizeof(uint32_t),1,f) != 1) return false;
    if(::fwrite(&meta.nbKangaroo,sizeof(uint64_t),1,f) != 1) return false;
  }

  return true;

}

bool Kangaroo::LoadThreadLayout(FILE *f) {

  loadedWorkHasThreadMeta = false;
  loadedWorkThreadMeta.clear();

  uint32_t magic = 0U;
  uint32_t threadCount = 0U;
  if(::fread(&magic,sizeof(uint32_t),1,f) != 1) {
    ::printf("LoadWork: ERROR - cannot read thread layout metadata magic\n");
    return false;
  }
  if(::fread(&threadCount,sizeof(uint32_t),1,f) != 1) {
    ::printf("LoadWork: ERROR - cannot read thread layout metadata count\n");
    return false;
  }
  if(magic != WORK_THREAD_META_MAGIC) {
    ::printf("LoadWork: ERROR - invalid thread layout metadata magic 0x%08X\n",magic);
    return false;
  }

  // v3 允许写入空线程布局，表示“没有可直接恢复的布局信息”，后续按 legacy 路径重排。
  if(threadCount == 0U) {
    loadedWorkHasThreadMeta = false;
    return true;
  }

  loadedWorkThreadMeta.reserve(threadCount);
  uint64_t totalWalk = 0ULL;
  for(uint32_t i = 0; i < threadCount; i++) {
    WORK_THREAD_META meta;
    memset(&meta,0,sizeof(meta));
    if(::fread(&meta.flags,sizeof(uint32_t),1,f) != 1) return false;
    if(::fread(&meta.gridSizeX,sizeof(uint32_t),1,f) != 1) return false;
    if(::fread(&meta.gridSizeY,sizeof(uint32_t),1,f) != 1) return false;
    if(::fread(&meta.groupSize,sizeof(uint32_t),1,f) != 1) return false;
    if(::fread(&meta.nbKangaroo,sizeof(uint64_t),1,f) != 1) return false;
    loadedWorkThreadMeta.push_back(meta);
    totalWalk += meta.nbKangaroo;
  }

  if(totalWalk != (uint64_t)nbLoadedWalk) {
    ::printf("LoadWork: ERROR - thread layout metadata count mismatch (%" PRIu64 " != %" PRIu64 ")\n",
             totalWalk,
             (uint64_t)nbLoadedWalk);
    loadedWorkThreadMeta.clear();
    return false;
  }

  loadedWorkHasThreadMeta = true;
  return true;

}

void Kangaroo::AllocateThreadKangaroos(TH_PARAM *threads,int nbThread) {

  for(int i = 0; i < nbThread; i++) {
    uint64_t n = threads[i].nbKangaroo;
    threads[i].px = new Int[n];
    threads[i].py = new Int[n];
    threads[i].distance = new Int[n];
#ifdef USE_SYMMETRY
    threads[i].symClass = new uint64_t[n];
    memset(threads[i].symClass,0,(size_t)n * sizeof(uint64_t));
#endif
  }

}

void Kangaroo::FreeThreadKangaroos(TH_PARAM *threads,int nbThread) {

  if(threads == NULL) {
    return;
  }

  for(int i = 0; i < nbThread; i++) {
    if(threads[i].px) {
      delete[] threads[i].px;
      threads[i].px = NULL;
    }
    if(threads[i].py) {
      delete[] threads[i].py;
      threads[i].py = NULL;
    }
    if(threads[i].distance) {
      delete[] threads[i].distance;
      threads[i].distance = NULL;
    }
#ifdef USE_SYMMETRY
    if(threads[i].symClass) {
      delete[] threads[i].symClass;
      threads[i].symClass = NULL;
    }
#endif
  }

}

bool Kangaroo::RebuildCleanHashTable(uint64_t *kept,uint64_t *removed,uint64_t *duplicates,uint64_t *conflicts) {

  uint64_t keptCount = 0ULL;
  uint64_t removedCount = 0ULL;
  uint64_t duplicateCount = 0ULL;
  uint64_t conflictCount = 0ULL;
  HashTable cleanTable;
  Point Z;
  Z.Clear();

  for(uint32_t h = 0; h < HASH_SIZE; h++) {
    uint32_t nbItem = hashTable.E[h].nbItem;
    if(nbItem == 0) {
      continue;
    }

    std::vector<Int> dists;
    std::vector<uint32_t> types;
    std::vector<Point> bases;
    dists.reserve(nbItem);
    types.reserve(nbItem);
    bases.reserve(nbItem);

    for(uint32_t i = 0; i < nbItem; i++) {
      ENTRY *e = hashTable.E[h].items[i];
      Int dist;
      uint32_t kType;
      HashTable::CalcDistAndType(e->d,&dist,&kType);
      dists.push_back(dist);
      types.push_back(kType);
      bases.push_back(kType == TAME ? Z : keyToSearch);
    }

    std::vector<Point> walks = secp->ComputePublicKeys(dists);
    std::vector<Point> expected = secp->AddDirect(bases,walks);
    std::vector<uint8_t> valid(nbItem,0U);
    std::vector<uint32_t> unresolvedWild;
    unresolvedWild.reserve(nbItem);

    for(uint32_t i = 0; i < nbItem; i++) {
      ENTRY *e = hashTable.E[h].items[i];
      bool ok = ((expected[i].x.bits64[2] & HASH_MASK) == h) &&
                (expected[i].x.bits64[0] == e->x.i64[0]) &&
                (expected[i].x.bits64[1] == e->x.i64[1]);
      if(ok) {
        valid[i] = 1U;
      } else if(types[i] == WILD) {
        unresolvedWild.push_back(i);
      }
    }

#ifdef USE_SYMMETRY
    if(!unresolvedWild.empty()) {
      std::vector<Point> altBases;
      std::vector<Point> altInputs;
      altBases.reserve(unresolvedWild.size());
      altInputs.reserve(unresolvedWild.size());
      for(uint32_t idx : unresolvedWild) {
        altBases.push_back(keyToSearchNeg);
        altInputs.push_back(walks[idx]);
      }
      std::vector<Point> altExpected = secp->AddDirect(altBases,altInputs);
      for(size_t j = 0; j < unresolvedWild.size(); j++) {
        uint32_t idx = unresolvedWild[j];
        ENTRY *e = hashTable.E[h].items[idx];
        bool ok = ((altExpected[j].x.bits64[2] & HASH_MASK) == h) &&
                  (altExpected[j].x.bits64[0] == e->x.i64[0]) &&
                  (altExpected[j].x.bits64[1] == e->x.i64[1]);
        if(ok) {
          valid[idx] = 1U;
        }
      }
    }
#endif

    for(uint32_t i = 0; i < nbItem; i++) {
      ENTRY *e = hashTable.E[h].items[i];
      if(valid[i] == 0U) {
        removedCount++;
        continue;
      }

      int addStatus = cleanTable.Add(h,&e->x,&e->d);
      if(addStatus == ADD_OK) {
        keptCount++;
      } else if(addStatus == ADD_DUPLICATE) {
        duplicateCount++;
      } else {
        conflictCount++;
      }
    }
  }

  hashTable.Reset();
  hashTable = cleanTable;

  if(kept) *kept = keptCount;
  if(removed) *removed = removedCount;
  if(duplicates) *duplicates = duplicateCount;
  if(conflicts) *conflicts = conflictCount;

  return true;

}

bool Kangaroo::RestoreKangaroosDirect(TH_PARAM *threads,int nbThread,std::vector<int192_t> *kangs) {

  for(int i = 0; i < nbThread; i++) {
    uint64_t n = threads[i].nbKangaroo;
    if(kangs == NULL)
      FetchWalks(n,
                 threads[i].px,
                 threads[i].py,
                 threads[i].distance,
#ifdef USE_SYMMETRY
                 threads[i].symClass
#else
                 NULL
#endif
                 );
    else
      FetchWalks(n,*kangs,
                 threads[i].px,
                 threads[i].py,
                 threads[i].distance,
#ifdef USE_SYMMETRY
                 threads[i].symClass
#else
                 NULL
#endif
                 );
  }

  return true;

}

bool Kangaroo::RestoreKangaroosReordered(TH_PARAM *threads,int nbThread,std::vector<int192_t> *kangs,
                                         bool tolerateInvalid,bool trustSourceMeta,uint64_t *invalidDiscarded,
                                         uint64_t *restoredCount,uint64_t *unhandledCount) {

  uint64_t droppedInvalid = 0ULL;

  std::vector<WORK_THREAD_META> targetMeta;
  targetMeta.reserve(nbThread);
  for(int i = 0; i < nbThread; i++) {
    targetMeta.push_back(GetThreadMeta(threads[i],i >= nbCPUThread));
  }

  // 先按当前几何生成一份全新的 herd，后续仅把旧状态覆盖到匹配槽位。
  for(int i = 0; i < nbCPUThread; i++) {
    CreateHerd(CPU_GRP_SIZE,threads[i].px,threads[i].py,threads[i].distance,TAME);
#ifdef USE_SYMMETRY
    if(threads[i].symClass != NULL) {
      memset(threads[i].symClass,0,(size_t)threads[i].nbKangaroo * sizeof(uint64_t));
    }
#endif
  }

#ifdef WITHGPU
  for(int i = nbCPUThread; i < nbThread; i++) {
    uint64_t n = threads[i].nbKangaroo;
    uint64_t y = (uint64_t)threads[i].gridSizeY;
    uint64_t gSize = (uint64_t)threads[i].groupSize;
    if(y == 0ULL || gSize == 0ULL || n != (uint64_t)threads[i].gridSizeX * y * gSize) {
      CreateHerd((int)n,threads[i].px,threads[i].py,threads[i].distance,TAME);
    } else {
      uint64_t walkersPerBlock = y * gSize;
      for(int b = 0; b < threads[i].gridSizeX; b++) {
        uint64_t blockBase = (uint64_t)b * walkersPerBlock;
        for(uint64_t g = 0; g < gSize; g++) {
          uint64_t base = blockBase + g * y;
          CreateHerd((int)y,
                     &(threads[i].px[base]),
                     &(threads[i].py[base]),
                     &(threads[i].distance[base]),
                     TAME);
        }
      }
    }
#ifdef USE_SYMMETRY
    if(threads[i].symClass != NULL) {
      memset(threads[i].symClass,0,(size_t)threads[i].nbKangaroo * sizeof(uint64_t));
    }
#endif
  }
#endif

  struct SlotCursor {
    int threadIndex;
    uint64_t localIndex;
  };
  SlotCursor cursors[2] = {{0,0ULL},{0,0ULL}};

  auto nextSlot = [&](uint32_t type,SlotCursor *cursor,int *threadIndex,uint64_t *localIndex) -> bool {
    while(cursor->threadIndex < nbThread) {
      const WORK_THREAD_META &meta = targetMeta[(size_t)cursor->threadIndex];
      while(cursor->localIndex < meta.nbKangaroo) {
        uint64_t idx = cursor->localIndex++;
        if(GetWalkerTypeForMeta(meta,idx) == type) {
          *threadIndex = cursor->threadIndex;
          *localIndex = idx;
          return true;
        }
      }
      cursor->threadIndex++;
      cursor->localIndex = 0ULL;
    }
    return false;
  };

  auto placeWalker = [&](const Int &x,const Int &y,const Int &d,uint64_t symClass,uint32_t type) -> bool {
    static_assert(TAME == 0 && WILD == 1,"kangaroo type enum must stay binary");
    int threadIndex = 0;
    uint64_t localIndex = 0ULL;
    if(!nextSlot(type,&cursors[type],&threadIndex,&localIndex)) {
      return false;
    }
    threads[threadIndex].px[localIndex] = x;
    threads[threadIndex].py[localIndex] = y;
    threads[threadIndex].distance[localIndex] = d;
#ifdef USE_SYMMETRY
    if(threads[threadIndex].symClass != NULL) {
      threads[threadIndex].symClass[localIndex] = symClass & 1ULL;
    }
#endif
    return true;
  };

  uint64_t remaining = (uint64_t)nbLoadedWalk;
  uint64_t restored = 0ULL;
  uint64_t unhandled = 0ULL;
  const uint64_t chunkSize = 4096ULL;

  auto processChunk = [&](const std::vector<Int> &xs,
                          const std::vector<Int> &ys,
                          const std::vector<Int> &ds,
                          const std::vector<uint64_t> &symClasses,
                          const std::vector<uint32_t> *knownTypes) -> bool {
    std::vector<uint32_t> resolvedTypes;
    if(knownTypes == NULL) {
      resolvedTypes.resize(xs.size());
      std::vector<Int> dists(ds.begin(),ds.end());
      std::vector<Point> walks = secp->ComputePublicKeys(dists);
      std::vector<size_t> unresolved;
      unresolved.reserve(xs.size());

      auto sameXAt = [&](const Point &p,size_t i) -> bool {
        return p.x.bits64[0] == xs[i].bits64[0] &&
               p.x.bits64[1] == xs[i].bits64[1] &&
               p.x.bits64[2] == xs[i].bits64[2] &&
               p.x.bits64[3] == xs[i].bits64[3];
      };

      for(size_t i = 0; i < xs.size(); i++) {
        if(sameXAt(walks[i],i)) {
          resolvedTypes[i] = TAME;
        } else {
          unresolved.push_back(i);
        }
      }

      if(!unresolved.empty()) {
        std::vector<Point> wildBases;
        std::vector<Point> wildInputs;
        wildBases.reserve(unresolved.size());
        wildInputs.reserve(unresolved.size());
        for(size_t idx : unresolved) {
          wildBases.push_back(keyToSearch);
          wildInputs.push_back(walks[idx]);
        }
        std::vector<Point> wilds = secp->AddDirect(wildBases,wildInputs);
        std::vector<size_t> unresolvedAlt;
        unresolvedAlt.reserve(unresolved.size());
        for(size_t j = 0; j < unresolved.size(); j++) {
          size_t idx = unresolved[j];
          if(sameXAt(wilds[j],idx)) {
            resolvedTypes[idx] = WILD;
          } else {
            unresolvedAlt.push_back(idx);
          }
        }

#ifdef USE_SYMMETRY
        if(!unresolvedAlt.empty()) {
          std::vector<Point> altBases;
          std::vector<Point> altInputs;
          altBases.reserve(unresolvedAlt.size());
          altInputs.reserve(unresolvedAlt.size());
          for(size_t idx : unresolvedAlt) {
            altBases.push_back(keyToSearchNeg);
            altInputs.push_back(walks[idx]);
          }
          std::vector<Point> wildAlt = secp->AddDirect(altBases,altInputs);
          std::vector<size_t> stillUnresolved;
          stillUnresolved.reserve(unresolvedAlt.size());
          for(size_t j = 0; j < unresolvedAlt.size(); j++) {
            size_t idx = unresolvedAlt[j];
            if(sameXAt(wildAlt[j],idx)) {
              resolvedTypes[idx] = WILD;
            } else {
              stillUnresolved.push_back(idx);
            }
          }
          unresolvedAlt.swap(stillUnresolved);
        }
        if(!unresolvedAlt.empty()) {
          if(!tolerateInvalid) {
            ::printf("FectchKangaroos: ERROR - cannot classify restored kangaroo #%zu\n",unresolvedAlt[0]);
            return false;
          }
          droppedInvalid += (uint64_t)unresolvedAlt.size();
          for(size_t idx : unresolvedAlt) {
            resolvedTypes[idx] = 2U;
          }
        }
#else
        if(!unresolvedAlt.empty()) {
          if(!tolerateInvalid) {
            ::printf("FectchKangaroos: ERROR - cannot classify restored kangaroo #%zu\n",unresolvedAlt[0]);
            return false;
          }
          droppedInvalid += (uint64_t)unresolvedAlt.size();
          for(size_t idx : unresolvedAlt) {
            resolvedTypes[idx] = 2U;
          }
        }
#endif
      }

      for(size_t i = 0; i < xs.size(); i++) {
        if(resolvedTypes[i] == 2U && tolerateInvalid) {
          continue;
        }
        if(resolvedTypes[i] != TAME && resolvedTypes[i] != WILD) {
          ::printf("FectchKangaroos: ERROR - unresolved kangaroo type at #%zu\n",i);
          return false;
        }
      }
      knownTypes = &resolvedTypes;
    }

    for(size_t i = 0; i < xs.size(); i++) {
      if((*knownTypes)[i] == 2U && tolerateInvalid) {
        continue;
      }
      if(placeWalker(xs[i],ys[i],ds[i],symClasses[i],(*knownTypes)[i])) {
        restored++;
      } else {
        unhandled++;
      }
    }
    return true;
  };

  std::vector<WORK_THREAD_META> sourceMeta;
  if(kangs != NULL) {
    WORK_THREAD_META meta;
    memset(&meta,0,sizeof(meta));
    meta.nbKangaroo = (uint64_t)kangs->size();
    sourceMeta.push_back(meta);
  } else if(loadedWorkHasThreadMeta) {
    sourceMeta = loadedWorkThreadMeta;
  } else {
    WORK_THREAD_META meta;
    memset(&meta,0,sizeof(meta));
    meta.nbKangaroo = (uint64_t)nbLoadedWalk;
    sourceMeta.push_back(meta);
  }

  for(size_t threadIdx = 0; threadIdx < sourceMeta.size() && remaining > 0ULL; threadIdx++) {
    const WORK_THREAD_META &meta = sourceMeta[threadIdx];
    uint64_t toRead = std::min<uint64_t>(meta.nbKangaroo,remaining);
    uint64_t sourceIndex = 0ULL;

    while(toRead > 0ULL) {
      uint64_t batch = std::min<uint64_t>(toRead,chunkSize);
      std::vector<Int> xs((size_t)batch);
      std::vector<Int> ys((size_t)batch);
      std::vector<Int> ds((size_t)batch);
      std::vector<uint64_t> symClasses((size_t)batch,0ULL);
      std::vector<uint32_t> knownTypes;
      bool haveKnownTypes = false;

      if(kangs == NULL) {
        if(loadedWorkHasThreadMeta && trustSourceMeta) {
          knownTypes.resize((size_t)batch);
          haveKnownTypes = true;
        }
        for(uint64_t i = 0; i < batch; i++) {
          ::fread(&xs[(size_t)i].bits64,32,1,fRead); xs[(size_t)i].bits64[4] = 0;
          ::fread(&ys[(size_t)i].bits64,32,1,fRead); ys[(size_t)i].bits64[4] = 0;
          ::fread(&ds[(size_t)i].bits64,32,1,fRead); ds[(size_t)i].bits64[4] = 0;
          if(loadedWorkHasSymClass) {
            uint64_t sc = 0ULL;
            ::fread(&sc,sizeof(uint64_t),1,fRead);
            symClasses[(size_t)i] = sc & 1ULL;
          }
          if(haveKnownTypes) {
            knownTypes[(size_t)i] = GetWalkerTypeForMeta(meta,sourceIndex + i);
          }
        }
      } else {
        knownTypes.resize((size_t)batch);
        haveKnownTypes = true;
        for(uint64_t i = 0; i < batch; i++) {
          Int dist;
          uint32_t type;
          HashTable::CalcDistAndType((*kangs)[(size_t)sourceIndex + (size_t)i],&dist,&type);
          Point walk = secp->ComputePublicKey(&dist);
          Point sum = walk;
          if(type == WILD) {
            sum = secp->AddDirect(keyToSearch,walk);
          }
          xs[(size_t)i].Set(&sum.x);
          ys[(size_t)i].Set(&sum.y);
          ds[(size_t)i].Set(&dist);
          knownTypes[(size_t)i] = type;
        }
      }

      if(!processChunk(xs,ys,ds,symClasses,haveKnownTypes ? &knownTypes : NULL)) {
        return false;
      }

      sourceIndex += batch;
      toRead -= batch;
      remaining -= batch;
      nbLoadedWalk -= (int64_t)batch;
    }
  }

  if(remaining > 0ULL) {
    unhandled += remaining;
    nbLoadedWalk -= (int64_t)remaining;
  }

  if(unhandled > 0ULL) {
    ::printf("FectchKangaroos: Warning %.0f unhandled kangaroos !\n",(double)unhandled);
  }
  if(invalidDiscarded != NULL) {
    *invalidDiscarded = droppedInvalid;
  }
  if(restoredCount != NULL) {
    *restoredCount = restored;
  }
  if(unhandledCount != NULL) {
    *unhandledCount = unhandled;
  }
  ::printf("FectchKangaroos: Repacked across geometry [%.0f restored] [%.0f kept fresh]",
           (double)restored,
           (double)(totalRW > restored ? totalRW - restored : 0ULL));
  if(droppedInvalid > 0ULL) {
    ::printf(" [%.0f invalid dropped]",(double)droppedInvalid);
  }
  ::printf("\n");

  return true;

}

bool Kangaroo::StreamRepairableKangaroos(FILE *fOut,uint64_t *kept,uint64_t *invalidDiscarded) {

  if(fOut == NULL) {
    return false;
  }

  uint64_t keptCount = 0ULL;
  uint64_t droppedInvalid = 0ULL;
  uint64_t remaining = (uint64_t)nbLoadedWalk;
  const uint64_t chunkSize = 4096ULL;

  auto sameXAt = [](const Point &p,const std::vector<Int> &xs,size_t i) -> bool {
    return p.x.bits64[0] == xs[i].bits64[0] &&
           p.x.bits64[1] == xs[i].bits64[1] &&
           p.x.bits64[2] == xs[i].bits64[2] &&
           p.x.bits64[3] == xs[i].bits64[3];
  };

  auto flushChunk = [&](const std::vector<Int> &xs,
                        const std::vector<Int> &ys,
                        const std::vector<Int> &ds,
                        const std::vector<uint64_t> &symClasses) -> bool {
    std::vector<uint32_t> resolvedTypes(xs.size(),2U);
    std::vector<Int> dists(ds.begin(),ds.end());
    std::vector<Point> walks = secp->ComputePublicKeys(dists);
    std::vector<size_t> unresolved;
    unresolved.reserve(xs.size());

    for(size_t i = 0; i < xs.size(); i++) {
      if(sameXAt(walks[i],xs,i)) {
        resolvedTypes[i] = TAME;
      } else {
        unresolved.push_back(i);
      }
    }

    if(!unresolved.empty()) {
      std::vector<Point> wildBases;
      std::vector<Point> wildInputs;
      wildBases.reserve(unresolved.size());
      wildInputs.reserve(unresolved.size());
      for(size_t idx : unresolved) {
        wildBases.push_back(keyToSearch);
        wildInputs.push_back(walks[idx]);
      }
      std::vector<Point> wilds = secp->AddDirect(wildBases,wildInputs);
      std::vector<size_t> unresolvedAlt;
      unresolvedAlt.reserve(unresolved.size());
      for(size_t j = 0; j < unresolved.size(); j++) {
        size_t idx = unresolved[j];
        if(sameXAt(wilds[j],xs,idx)) {
          resolvedTypes[idx] = WILD;
        } else {
          unresolvedAlt.push_back(idx);
        }
      }

#ifdef USE_SYMMETRY
      if(!unresolvedAlt.empty()) {
        std::vector<Point> altBases;
        std::vector<Point> altInputs;
        altBases.reserve(unresolvedAlt.size());
        altInputs.reserve(unresolvedAlt.size());
        for(size_t idx : unresolvedAlt) {
          altBases.push_back(keyToSearchNeg);
          altInputs.push_back(walks[idx]);
        }
        std::vector<Point> wildAlt = secp->AddDirect(altBases,altInputs);
        std::vector<size_t> stillUnresolved;
        stillUnresolved.reserve(unresolvedAlt.size());
        for(size_t j = 0; j < unresolvedAlt.size(); j++) {
          size_t idx = unresolvedAlt[j];
          if(sameXAt(wildAlt[j],xs,idx)) {
            resolvedTypes[idx] = WILD;
          } else {
            stillUnresolved.push_back(idx);
          }
        }
        unresolvedAlt.swap(stillUnresolved);
      }
#endif
      droppedInvalid += (uint64_t)unresolvedAlt.size();
    }

    for(size_t i = 0; i < xs.size(); i++) {
      if(resolvedTypes[i] == 2U) {
        continue;
      }
      if(::fwrite(&xs[i].bits64,32,1,fOut) != 1) return false;
      if(::fwrite(&ys[i].bits64,32,1,fOut) != 1) return false;
      if(::fwrite(&ds[i].bits64,32,1,fOut) != 1) return false;
#ifdef USE_SYMMETRY
      uint64_t sc = symClasses[i] & 1ULL;
      if(::fwrite(&sc,sizeof(uint64_t),1,fOut) != 1) return false;
#endif
      keptCount++;
    }

    return true;
  };

  std::vector<WORK_THREAD_META> sourceMeta;
  if(loadedWorkHasThreadMeta && !loadedWorkThreadMeta.empty()) {
    sourceMeta = loadedWorkThreadMeta;
  } else {
    WORK_THREAD_META meta;
    memset(&meta,0,sizeof(meta));
    meta.nbKangaroo = remaining;
    sourceMeta.push_back(meta);
  }

  for(size_t threadIdx = 0; threadIdx < sourceMeta.size() && remaining > 0ULL; threadIdx++) {
    uint64_t toRead = std::min<uint64_t>(sourceMeta[threadIdx].nbKangaroo,remaining);
    while(toRead > 0ULL) {
      uint64_t batch = std::min<uint64_t>(toRead,chunkSize);
      std::vector<Int> xs((size_t)batch);
      std::vector<Int> ys((size_t)batch);
      std::vector<Int> ds((size_t)batch);
      std::vector<uint64_t> symClasses((size_t)batch,0ULL);

      for(uint64_t i = 0; i < batch; i++) {
        ::fread(&xs[(size_t)i].bits64,32,1,fRead); xs[(size_t)i].bits64[4] = 0;
        ::fread(&ys[(size_t)i].bits64,32,1,fRead); ys[(size_t)i].bits64[4] = 0;
        ::fread(&ds[(size_t)i].bits64,32,1,fRead); ds[(size_t)i].bits64[4] = 0;
        if(loadedWorkHasSymClass) {
          uint64_t sc = 0ULL;
          ::fread(&sc,sizeof(uint64_t),1,fRead);
          symClasses[(size_t)i] = sc & 1ULL;
        }
      }

      if(!flushChunk(xs,ys,ds,symClasses)) {
        return false;
      }

      toRead -= batch;
      remaining -= batch;
      nbLoadedWalk -= (int64_t)batch;
    }
  }

  if(remaining > 0ULL) {
    droppedInvalid += remaining;
    nbLoadedWalk -= (int64_t)remaining;
  }

  if(kept != NULL) {
    *kept = keptCount;
  }
  if(invalidDiscarded != NULL) {
    *invalidDiscarded = droppedInvalid;
  }

  return true;

}

// ----------------------------------------------------------------------------

void Kangaroo::FetchWalks(uint64_t nbWalk,Int *x,Int *y,Int *d,uint64_t *symClass) {

  // Read Kangaroos
  int64_t n = 0;

  ::printf("Fetch kangaroos: %.0f\n",(double)nbWalk);

  for(n = 0; n < (int64_t)nbWalk && nbLoadedWalk>0; n++) {
    ::fread(&x[n].bits64,32,1,fRead); x[n].bits64[4] = 0;
    ::fread(&y[n].bits64,32,1,fRead); y[n].bits64[4] = 0;
    ::fread(&d[n].bits64,32,1,fRead); d[n].bits64[4] = 0;
    if(loadedWorkHasSymClass) {
      uint64_t sc = 0;
      ::fread(&sc,sizeof(uint64_t),1,fRead);
      if(symClass != NULL) {
        symClass[n] = sc & 1ULL;
      }
    } else if(symClass != NULL) {
      symClass[n] = 0ULL;
    }
    nbLoadedWalk--;
  }

  if(n<(int64_t)nbWalk) {
    int64_t empty = nbWalk - n;
    // Fill empty kanagaroo
    CreateHerd((int)empty,&(x[n]),&(y[n]),&(d[n]),TAME);
    if(symClass != NULL) {
      memset(symClass + n,0,(size_t)empty * sizeof(uint64_t));
    }
  }

}

void Kangaroo::FetchWalks(uint64_t nbWalk,std::vector<int192_t>& kangs,Int* x,Int* y,Int* d,uint64_t *symClass) {

  uint64_t n = 0;

  uint64_t avail = (nbWalk<kangs.size())?nbWalk:kangs.size();

  if(avail > 0) {

    vector<Int> dists;
    vector<uint32_t> types;
    vector<Point> Sp;
    dists.reserve(avail);
    types.reserve(avail);
    Sp.reserve(avail);
    Point Z;
    Z.Clear();

    for(n = 0; n < avail; n++) {

      Int dist;
      uint32_t type;
      HashTable::CalcDistAndType(kangs[n],&dist,&type);
      dists.push_back(dist);
      types.push_back(type);

    }

    vector<Point> P = secp->ComputePublicKeys(dists);

    for(n = 0; n < avail; n++) {

      if(types[n] == TAME) {
        Sp.push_back(Z);
      }
      else {
        Sp.push_back(keyToSearch);
      }

    }

    vector<Point> S = secp->AddDirect(Sp,P);

    for(n = 0; n < avail; n++) {
      x[n].Set(&S[n].x);
      y[n].Set(&S[n].y);
      d[n].Set(&dists[n]);
      if(symClass != NULL) {
        symClass[n] = 0ULL;
      }
      nbLoadedWalk--;
    }

    kangs.erase(kangs.begin(),kangs.begin() + avail);

  }

  if(avail < nbWalk) {
    int64_t empty = nbWalk - avail;
    // Fill empty kanagaroo
    CreateHerd((int)empty,&(x[n]),&(y[n]),&(d[n]),TAME);
    if(symClass != NULL) {
      memset(symClass + n,0,(size_t)empty * sizeof(uint64_t));
    }
  }

}

void Kangaroo::FectchKangaroos(TH_PARAM *threads) {

  double sFetch = Timer::get_tick();

  // From server
  vector<int192_t> kangs;
  if(saveKangarooByServer) {
    ::printf("FectchKangaroosFromServer");
    if(!GetKangaroosFromServer(workFile,kangs))
      ::exit(0);
    ::printf("Done\n");
    nbLoadedWalk = kangs.size();
  }


  // Fetch input kangaroo from file (if any)
  if(nbLoadedWalk>0) {

    ::printf("Restoring");

    uint64_t nbSaved = nbLoadedWalk;
    uint64_t created = 0;
    int nbThread = nbCPUThread + nbGPUThread;
    AllocateThreadKangaroos(threads,nbThread);

    bool canRestoreDirect = false;
    if(!saveKangarooByServer && loadedWorkHasThreadMeta &&
       (int)loadedWorkThreadMeta.size() == nbThread) {
      canRestoreDirect = true;
      for(int i = 0; i < nbThread; i++) {
        if(!IsThreadMetaCompatible(loadedWorkThreadMeta[(size_t)i],threads[i],i >= nbCPUThread)) {
          canRestoreDirect = false;
          break;
        }
      }
    }

    bool ok = false;
    if(canRestoreDirect) {
      ::printf(" [direct]");
      ok = RestoreKangaroosDirect(threads,nbThread,NULL);
    } else if(saveKangarooByServer) {
      ::printf(" [repack:server]");
      ok = RestoreKangaroosReordered(threads,nbThread,&kangs,false,true,NULL);
    } else {
      if(loadedWorkHasThreadMeta) {
        ::printf(" [repack:geometry]");
      } else {
        ::printf(" [repack:legacy]");
      }
      ok = RestoreKangaroosReordered(threads,nbThread,NULL,false,true,NULL);
    }
    if(!ok) {
      ::printf("\nFectchKangaroos: failed to restore kangaroo state\n");
      if(fRead) {
        fclose(fRead);
        fRead = NULL;
      }
      ::exit(0);
    }

    ::printf("Done\n");

    double eFetch = Timer::get_tick();

    if(nbLoadedWalk != 0 && !saveKangarooByServer) {
      ::printf("FectchKangaroos: Warning %.0f unhandled kangaroos !\n",(double)nbLoadedWalk);
    }

    if(nbSaved<totalRW)
      created = totalRW - nbSaved;

    ::printf("FectchKangaroos: [2^%.2f kangaroos loaded] [%.0f created] [%s]\n",log2((double)nbSaved),(double)created,GetTimeStr(eFetch - sFetch).c_str());

  }

  // Close input file
  if(fRead) fclose(fRead);

}


// ----------------------------------------------------------------------------
bool Kangaroo::SaveHeader(string fileName,FILE* f,int type,uint64_t totalCount,double totalTime) {

  // Header
  uint32_t head = type;
  // 当前版本增加线程布局元数据，用于跨几何恢复时重排 kangaroo 顺序。
  uint32_t version = GetCurrentWorkFileVersion();
  if(::fwrite(&head,sizeof(uint32_t),1,f) != 1) {
    ::printf("SaveHeader: Cannot write to %s\n",fileName.c_str());
    ::printf("%s\n",::strerror(errno));
    return false;
  }
  ::fwrite(&version,sizeof(uint32_t),1,f);

  if(type==HEADW) {

    // Save global param
    ::fwrite(&dpSize,sizeof(uint32_t),1,f);
    ::fwrite(&rangeStart.bits64,32,1,f);
    ::fwrite(&rangeEnd.bits64,32,1,f);
    ::fwrite(&keysToSearch[keyIdx].x.bits64,32,1,f);
    ::fwrite(&keysToSearch[keyIdx].y.bits64,32,1,f);
    ::fwrite(&totalCount,sizeof(uint64_t),1,f);
    ::fwrite(&totalTime,sizeof(double),1,f);

  }

  return true;
}

void  Kangaroo::SaveWork(string fileName,FILE *f,int type,uint64_t totalCount,double totalTime) {

  ::printf("\nSaveWork: %s",fileName.c_str());

  // Header
  if(!SaveHeader(fileName,f,type,totalCount,totalTime))
    return;

  // Save hash table
  hashTable.SaveTable(f);

}

void Kangaroo::SaveServerWork() {

  saveRequest.store(true,std::memory_order_release);

  double t0 = Timer::get_tick();

  string fileName = workFile;
  if(splitWorkfile)
    fileName = workFile + "_" + Timer::getTS();

  FILE *f = fopen(fileName.c_str(),"wb");
  if(f == NULL) {
    ::printf("\nSaveWork: Cannot open %s for writing\n",fileName.c_str());
    ::printf("%s\n",::strerror(errno));
    saveRequest.store(false,std::memory_order_release);
    return;
  }

  SaveWork(fileName,f,HEADW,0,0);

  uint64_t totalWalk = 0;
  ::fwrite(&totalWalk,sizeof(uint64_t),1,f);
  SaveThreadLayout(f,NULL,0);

  uint64_t size = FTell(f);
  fclose(f);

  if(splitWorkfile)
    hashTable.Reset();

  double t1 = Timer::get_tick();

  char *ctimeBuff;
  time_t now = time(NULL);
  ctimeBuff = ctime(&now);
  ::printf("done [%.1f MB] [%s] %s",(double)size / (1024.0*1024.0),GetTimeStr(t1 - t0).c_str(),ctimeBuff);

  saveRequest.store(false,std::memory_order_release);

}

void Kangaroo::SaveWork(uint64_t totalCount,double totalTime,TH_PARAM *threads,int nbThread) {

  uint64_t totalWalk = 0;
  uint64_t size;

  LOCK(saveMutex);

  double t0 = Timer::get_tick();

  // Wait that all threads blocks before saving works
  saveRequest.store(true,std::memory_order_release);
  int timeout = wtimeout;
  while(!isWaiting(threads) && timeout>0) {
    Timer::SleepMillis(50);
    timeout -= 50;
  }

  if(timeout<=0) {
    // Thread blocked or ended !
    if(!endOfSearch)
      ::printf("\nSaveWork timeout !\n");
    saveRequest.store(false,std::memory_order_release);
    UNLOCK(saveMutex);
    return;
  }

  string fileName = workFile;
  if(splitWorkfile)
    fileName = workFile + "_" + Timer::getTS();

  // Save
  FILE* f = NULL;
  if(!saveKangarooByServer) {
    f = fopen(fileName.c_str(),"wb");
    if(f == NULL) {
      ::printf("\nSaveWork: Cannot open %s for writing\n",fileName.c_str());
      ::printf("%s\n",::strerror(errno));
      saveRequest.store(false,std::memory_order_release);
      UNLOCK(saveMutex);
      return;
    }
  }

  if (clientMode) {

    if(saveKangarooByServer) {

      ::printf("\nSaveWork (Kangaroo->Server): %s",fileName.c_str());
      vector<int192_t> kangs;
      for(int i = 0; i < nbThread; i++)
        totalWalk += threads[i].nbKangaroo;
      kangs.reserve(totalWalk);

      for(int i = 0; i < nbThread; i++) {
        int128_t X;
        int192_t D;
        uint64_t h;
        for(uint64_t n = 0; n < threads[i].nbKangaroo; n++) {
          HashTable::Convert(&threads[i].px[n],&threads[i].distance[n],n%2,&h,&X,&D);
          kangs.push_back(D);
        }
      }
      SendKangaroosToServer(fileName,kangs);
      size = kangs.size()*sizeof(int192_t) + 16;
      goto end;

    } else {
      SaveHeader(fileName,f,HEADK,totalCount,totalTime);
      ::printf("\nSaveWork (Kangaroo): %s",fileName.c_str());
    }

  } else {

    SaveWork(fileName,f,HEADW,totalCount,totalTime);

  }


  if(saveKangaroo) {

    // Save kangaroos
    for(int i = 0; i < nbThread; i++)
      totalWalk += threads[i].nbKangaroo;
    ::fwrite(&totalWalk,sizeof(uint64_t),1,f);
    SaveThreadLayout(f,threads,nbThread);

    uint64_t point = totalWalk / 16;
    uint64_t pointPrint = 0;

    for(int i = 0; i < nbThread; i++) {
      for(uint64_t n = 0; n < threads[i].nbKangaroo; n++) {
        ::fwrite(&threads[i].px[n].bits64,32,1,f);
        ::fwrite(&threads[i].py[n].bits64,32,1,f);
        ::fwrite(&threads[i].distance[n].bits64,32,1,f);
#ifdef USE_SYMMETRY
        uint64_t sc = 0ULL;
        if(threads[i].symClass != NULL) {
          sc = threads[i].symClass[n] & 1ULL;
        }
        ::fwrite(&sc,sizeof(uint64_t),1,f);
#endif
        pointPrint++;
        if(pointPrint>point) {
          ::printf(".");
          pointPrint = 0;
        }
      }
    }

  } else {

    ::fwrite(&totalWalk,sizeof(uint64_t),1,f);
    SaveThreadLayout(f,threads,nbThread);

  }

  size = FTell(f);
  fclose(f);

  if(splitWorkfile)
    hashTable.Reset();

  // Unblock threads
end:
  saveRequest.store(false,std::memory_order_release);
  UNLOCK(saveMutex);

  double t1 = Timer::get_tick();

  char *ctimeBuff;
  time_t now = time(NULL);
  ctimeBuff = ctime(&now);
  ::printf("done [%.1f MB] [%s] %s",(double)size/(1024.0*1024.0),GetTimeStr(t1 - t0).c_str(),ctimeBuff);

}

bool Kangaroo::CleanWorkFile(int reqCPUThread,std::vector<int> gpuId,std::vector<int> gridSize,
                             std::string &inputFile,std::string &outputFile) {

  (void)reqCPUThread;
  (void)gpuId;
  (void)gridSize;

  if(IsDir(inputFile)) {
    ::printf("wclean: partitioned work directory is not supported yet\n");
    return false;
  }

  if(!LoadWork(inputFile)) {
    return false;
  }

  InitRange();
  CreateJumpTable();
  keyIdx = 0;
  InitSearchKey();
  SetDP(initDPSize);

  uint64_t kept = 0ULL;
  uint64_t removed = 0ULL;
  uint64_t duplicates = 0ULL;
  uint64_t conflicts = 0ULL;
  ::printf("Cleaning DP");
  if(!RebuildCleanHashTable(&kept,&removed,&duplicates,&conflicts)) {
    if(fRead) {
      fclose(fRead);
      fRead = NULL;
    }
    return false;
  }
  ::printf(": [kept %" PRIu64 "] [removed %" PRIu64 "] [duplicate %" PRIu64 "] [conflict %" PRIu64 "]\n",
           kept,removed,duplicates,conflicts);

  uint64_t sourceWalk = (uint64_t)nbLoadedWalk;
  uint64_t invalidDiscarded = 0ULL;
  uint64_t repairedCount = 0ULL;

  FILE *fOut = fopen(outputFile.c_str(),"wb");
  if(fOut == NULL) {
    ::printf("wclean: Cannot open %s for writing\n",outputFile.c_str());
    ::printf("%s\n",::strerror(errno));
    if(fRead) {
      fclose(fRead);
      fRead = NULL;
    }
    return false;
  }

  ::printf("Writing clean work: %s",outputFile.c_str());
  SaveWork(outputFile,fOut,HEADW,offsetCount,offsetTime);

  uint64_t totalWalkPos = FTell(fOut);
  uint64_t zeroWalk = 0ULL;
  ::fwrite(&zeroWalk,sizeof(uint64_t),1,fOut);
  SaveThreadLayout(fOut,NULL,0);

  if(sourceWalk > 0ULL) {
    ::printf("Repairing kangaroos");
    if(!StreamRepairableKangaroos(fOut,&repairedCount,&invalidDiscarded)) {
      if(fRead) {
        fclose(fRead);
        fRead = NULL;
      }
      fclose(fOut);
      return false;
    }
  }

  uint64_t endPos = FTell(fOut);
  FSeek(fOut,totalWalkPos);
  ::fwrite(&repairedCount,sizeof(uint64_t),1,fOut);
  FSeek(fOut,endPos);
  fclose(fOut);

  if(fRead) {
    fclose(fRead);
    fRead = NULL;
  }

  ::printf("done [%.1f MB]\n",(double)endPos / (1024.0 * 1024.0));
  ::printf("wclean: [source kangaroos %" PRIu64 "] [preserved %" PRIu64 "]",
           sourceWalk,repairedCount);
  if(invalidDiscarded > 0ULL) {
    ::printf(" [invalid dropped %" PRIu64 "]",invalidDiscarded);
  }
  ::printf("\n");
  return true;

}

void Kangaroo::WorkInfo(std::string &fName) {

  int isDir = IsDir(fName);
  if(isDir<0)
    return;

  string fileName = fName;
  if(isDir)
    fileName = fName + "/header";

  ::printf("Loading: %s\n",fileName.c_str());

  uint32_t version;
  FILE *f1 = ReadHeader(fileName,&version,HEADW);
  if(f1 == NULL)
    return;

#ifndef WIN64
#ifndef __APPLE__
  int fd = fileno(f1);
  posix_fadvise(fd,0,0,POSIX_FADV_RANDOM|POSIX_FADV_NOREUSE);
#endif
#endif

  uint32_t dp1;
  Point k1;
  uint64_t count1;
  double time1;
  Int RS1;
  Int RE1;

  // Read global param
  ::fread(&dp1,sizeof(uint32_t),1,f1);
  ::fread(&RS1.bits64,32,1,f1); RS1.bits64[4] = 0;
  ::fread(&RE1.bits64,32,1,f1); RE1.bits64[4] = 0;
  ::fread(&k1.x.bits64,32,1,f1); k1.x.bits64[4] = 0;
  ::fread(&k1.y.bits64,32,1,f1); k1.y.bits64[4] = 0;
  ::fread(&count1,sizeof(uint64_t),1,f1);
  ::fread(&time1,sizeof(double),1,f1);

  k1.z.SetInt32(1);
  if(!secp->EC(k1)) {
    ::printf("WorkInfo: key1 does not lie on elliptic curve\n");
    fclose(f1);
    return;
  }

  // Read hashTable
  if(isDir) {
    for(int i = 0; i < MERGE_PART; i++) {
      FILE* f = OpenPart(fName,"rb",i);
      hashTable.SeekNbItem(f,i * H_PER_PART,(i + 1) * H_PER_PART);
      fclose(f);
    }
  } else {
    hashTable.SeekNbItem(f1);
  }

  ::printf("Version   : %d\n",version);
  ::printf("DP bits   : %d\n",dp1);
  ::printf("Start     : %s\n",RS1.GetBase16().c_str());
  ::printf("Stop      : %s\n",RE1.GetBase16().c_str());
  ::printf("Key       : %s\n",secp->GetPublicKeyHex(true,k1).c_str());
#ifdef WIN64
  ::printf("Count     : %I64d 2^%.3f\n",count1,log2(count1));
#else
  ::printf("Count     : %" PRId64 " 2^%.3f\n",count1,log2(count1));
#endif
  ::printf("Time      : %s\n",GetTimeStr(time1).c_str());
  hashTable.PrintInfo();

  fread(&nbLoadedWalk,sizeof(uint64_t),1,f1);
#ifdef WIN64
  if(nbLoadedWalk > 0) {
    ::printf("Kangaroos : %I64d 2^%.3f\n",nbLoadedWalk,log2(nbLoadedWalk));
  } else {
    ::printf("Kangaroos : %I64d\n",nbLoadedWalk);
  }
#else
  if(nbLoadedWalk > 0) {
    ::printf("Kangaroos : %" PRId64 " 2^%.3f\n",nbLoadedWalk,log2(nbLoadedWalk));
  } else {
    ::printf("Kangaroos : %" PRId64 "\n",nbLoadedWalk);
  }
#endif

  if(WorkFileHasThreadMeta(version)) {
    uint32_t magic = 0U;
    uint32_t threadCount = 0U;
    if(::fread(&magic,sizeof(uint32_t),1,f1) == 1 &&
       ::fread(&threadCount,sizeof(uint32_t),1,f1) == 1 &&
       magic == WORK_THREAD_META_MAGIC) {
      if(threadCount == 0U) {
        ::printf("ThreadMeta: no\n");
      } else {
        ::printf("ThreadMeta: yes (%u threads)\n",threadCount);
        for(uint32_t i = 0; i < threadCount; i++) {
          WORK_THREAD_META meta;
          memset(&meta,0,sizeof(meta));
          if(::fread(&meta.flags,sizeof(uint32_t),1,f1) != 1) break;
          if(::fread(&meta.gridSizeX,sizeof(uint32_t),1,f1) != 1) break;
          if(::fread(&meta.gridSizeY,sizeof(uint32_t),1,f1) != 1) break;
          if(::fread(&meta.groupSize,sizeof(uint32_t),1,f1) != 1) break;
          if(::fread(&meta.nbKangaroo,sizeof(uint64_t),1,f1) != 1) break;
          if((meta.flags & WORK_THREAD_META_GPU) != 0U) {
            ::printf("  Thread[%u]: GPU grid=(%u,%u) grp=%u kangaroos=%" PRIu64 "\n",
                     i,
                     meta.gridSizeX,
                     meta.gridSizeY,
                     meta.groupSize,
                     meta.nbKangaroo);
          } else {
            ::printf("  Thread[%u]: CPU kangaroos=%" PRIu64 "\n",i,meta.nbKangaroo);
          }
        }
      }
    } else {
      ::printf("ThreadMeta: invalid or missing\n");
    }
  } else {
    ::printf("ThreadMeta: no\n");
  }

  fclose(f1);

}
