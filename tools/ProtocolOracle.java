package dev.imulink.baduanjin.wit;
import java.io.*;
import java.util.*;
/** Run the unchanged Android production parser; no Android runtime or sensor connection. */
public class ProtocolOracle {
 public static void main(String[] args)throws Exception {
  BufferedReader reader=new BufferedReader(new FileReader(args[0]));String line;
  while((line=reader.readLine())!=null){Protocol.Parser parser=new Protocol.Parser();List<Protocol.Frame> frames=new ArrayList<>();
   for(String chunk:line.split("\\|",-1)){byte[] bytes=new byte[chunk.length()/2];for(int i=0;i<bytes.length;i++)bytes[i]=(byte)Integer.parseInt(chunk.substring(i*2,i*2+2),16);frames.addAll(parser.accept(bytes));}
   StringBuilder out=new StringBuilder("{\"frames\":[");boolean first=true;
   for(Protocol.Frame f:frames){if(!first)out.append(',');first=false;out.append("{\"hex\":\"").append(Protocol.hex(f.bytes)).append("\",\"register\":").append(f.register).append(",\"words\":").append(Arrays.toString(f.words)).append(",\"kind\":\"").append(f.type()).append("\"}");}
   out.append("],\"discarded\":").append(parser.discarded).append(",\"pending\":").append(parser.pendingBytes()).append('}');System.out.println(out);
  }
 }
}
