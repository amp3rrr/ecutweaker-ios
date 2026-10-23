package org.quark.dr.ecu;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.text.DecimalFormat;
import java.text.DecimalFormatSymbols;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Locale;
import java.util.Random;

/** Generates reference outputs from the ORIGINAL Java EcuTweaker code. */
public class Oracle {
    static String hex(byte[] b) { return Ecu.byteArrayToHex(b); }

    public static void main(String[] a) throws Exception {
        if (a[0].equals("format")) { formats(a[1], Long.parseLong(a[2]), Integer.parseInt(a[3])); return; }
        String file = a[0];
        PrintWriter out = new PrintWriter(a[1], "UTF-8");
        Random rnd = new Random(Long.parseLong(a[2]));
        int iters = Integer.parseInt(a[3]);
        String json = new String(Files.readAllBytes(Paths.get(file)), StandardCharsets.UTF_8);
        Ecu ecu = new Ecu(json);
        JSONObject def = new JSONObject(json);
        JSONObject data = def.getJSONObject("data");
        JSONArray reqs = def.getJSONArray("requests");

        JSONObject sds = new JSONObject();
        for (String k : ecu.getSdsrequests().keySet()) sds.put(k, ecu.getSdsrequests().get(k));
        out.println(new JSONObject().put("kind", "sds").put("default", ecu.getDefaultSDS()).put("sds", sds));

        for (int r = 0; r < reqs.length(); ++r) {
            JSONObject req = reqs.getJSONObject(r);
            String name = req.getString("name");
            JSONObject recv = req.optJSONObject("receivebyte_dataitems");
            if (recv != null && recv.length() > 0) {
                int need = 1;
                Iterator<String> ks = recv.keys();
                while (ks.hasNext()) {
                    String k = ks.next();
                    JSONObject it = recv.getJSONObject(k);
                    int fb = it.optInt("firstbyte", 0), bo = it.optInt("bitoffset", 0);
                    JSONObject d = data.optJSONObject(k);
                    int bits = d == null ? 8 : d.optInt("bitscount", 8);
                    need = Math.max(need, fb - 1 + (bits + bo + 7) / 8);
                }
                for (int i = 0; i < iters; ++i) {
                    int len = need + (rnd.nextInt(6) == 0 ? -1 : rnd.nextInt(3));
                    if (len < 0) len = 0;
                    byte[] bytes = new byte[len];
                    rnd.nextBytes(bytes);
                    if (rnd.nextInt(4) == 0) for (int j = 0; j < len; ++j) bytes[j] = (byte) (rnd.nextInt(3) == 0 ? 0 : (rnd.nextInt(2) == 0 ? 0xFF : bytes[j]));
                    JSONObject o = new JSONObject().put("kind", "decode").put("req", name).put("bytes", hex(bytes));
                    try {
                        HashMap<String, String> v = ecu.getRequestValues(bytes, name, true);
                        JSONObject vo = new JSONObject();
                        for (String k : v.keySet()) vo.put(k, v.get(k));
                        o.put("values", vo);
                    } catch (Throwable e) {
                        o.put("error", e.getClass().getSimpleName());
                    }
                    out.println(o);
                }
            }
            JSONObject send = req.optJSONObject("sendbyte_dataitems");
            if (send != null && send.length() > 0) {
                for (int i = 0; i < iters; ++i) {
                    HashMap<String, Object> vals = new HashMap<>();
                    JSONObject vo = new JSONObject();
                    JSONArray order = new JSONArray();
                    Iterator<String> ks = send.keys();
                    while (ks.hasNext()) {
                        String k = ks.next();
                        Ecu.EcuData d = ecu.getData(k);
                        if (d == null) continue;
                        String v;
                        if (!d.items.isEmpty() && rnd.nextInt(5) != 0) {
                            Object[] keys = d.items.keySet().toArray();
                            v = (String) keys[rnd.nextInt(keys.length)];
                        } else if (d.bytesascii) {
                            int n = rnd.nextInt(d.bytescount + 3);
                            StringBuilder sb = new StringBuilder();
                            for (int j = 0; j < n; ++j) sb.append((char) (0x20 + rnd.nextInt(0x5f)));
                            v = sb.toString();
                        } else if (d.scaled) {
                            long maxRaw = d.bitscount >= 31 ? Integer.MAX_VALUE : (1L << d.bitscount) - 1;
                            long raw = (long) (rnd.nextDouble() * maxRaw);
                            float f = ((float) raw * d.step + d.offset) / d.divideby;
                            int mode = rnd.nextInt(4);
                            if (mode == 0) v = String.valueOf(raw);
                            else if (mode == 1) v = String.format(Locale.US, "%.3f", f);
                            else if (mode == 2) v = String.format(Locale.US, "%.1f", f).replace(".", ",");
                            else v = String.valueOf(f);
                        } else {
                            int digits = Math.max(1, (d.bitscount + 3) / 4);
                            StringBuilder sb = new StringBuilder();
                            for (int j = 0; j < digits; ++j) sb.append("0123456789ABCDEF".charAt(rnd.nextInt(16)));
                            v = sb.toString();
                        }
                        vals.put(k, v);
                        vo.put(k, v);
                        order.put(k);
                    }
                    JSONObject o = new JSONObject().put("kind", "encode").put("req", name).put("values", vo).put("order", order);
                    try {
                        byte[] f = ecu.setRequestValues(name, vals);
                        o.put("frame", hex(f));
                    } catch (Throwable e) {
                        o.put("error", e.getClass().getSimpleName());
                    }
                    out.println(o);
                }
            }
        }
        out.close();
    }

    static void formats(String outPath, long seed, int iters) throws Exception {
        PrintWriter out = new PrintWriter(outPath, "UTF-8");
        Random rnd = new Random(seed);
        String[] patterns = {"00.0", "0.00", "######0", "####0", "###0", "0.000", "000.0", "00", "00.00", "#.##", "#,##0.0", "0"};
        float[] steps = {1f, 0.1f, 0.01f, 0.0078125f, 0.09775f, 0.082f, 0.0316831683f, 100f, 3500f, 5f, 200f};
        float[] divs = {1f, 10f, 100f, 255f, 1023f, 65535f, 64f, 128f, 320f, 1186f};
        float[] offs = {0f, -40f, 830f, -0.14f, -3276750f};
        Ecu ecu = new Ecu("{\"requests\":[],\"devices\":[],\"data\":{}}");
        for (int i = 0; i < iters; ++i) {
            int val = rnd.nextInt(3) == 0 ? rnd.nextInt(256) - 128 : rnd.nextInt(65536);
            float step = steps[rnd.nextInt(steps.length)], div = divs[rnd.nextInt(divs.length)], off = offs[rnd.nextInt(offs.length)];
            float res = ((float) val * step + off) / div;
            JSONObject o = new JSONObject().put("bits", Float.floatToIntBits(res));
            JSONObject fo = new JSONObject();
            for (String p : patterns) {
                DecimalFormat df = new DecimalFormat(p, new DecimalFormatSymbols(Locale.US));
                fo.put(p, df.format(res));
            }
            o.put("df", fo);
            Ecu.EcuData d = ecu.new EcuData(new JSONObject(), "x");
            o.put("fmt", d.fmt(res));
            out.println(o);
        }
        out.close();
    }
}
