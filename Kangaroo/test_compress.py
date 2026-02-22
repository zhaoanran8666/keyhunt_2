def mod_sub_k1_order(a, b):
    N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    res = a - b
    if res < 0:
        res += N
    return res

def mod_neg_k1_order(a):
    N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    res = -a
    if res < 0:
        res += N
    return res

for d in [10, 0, 1000]:
  d_neg = mod_neg_k1_order(d)
  d_wild = mod_sub_k1_order(d_neg, 20)
  
  d0 = d_wild & ((1<<64)-1)
  d1 = (d_wild >> 64) & ((1<<64)-1)
  d2 = (d_wild >> 128) & ((1<<64)-1)
  d3 = (d_wild >> 192) & ((1<<64)-1)
  print(f"dist={d} -> d3={hex(d3)} d2={hex(d2)} d1={hex(d1)} d0={hex(d0)}")
