package body NF_Const is
  procedure Processor(Data: in out Packet_Data;
                      Length: in Packet_Length;
                      Output_Lengths: not null access Agent.Packet_Outputs) is
  begin
    Data(0) := 0;
    Data(1) := 0;
    Data(2) := 0;
    Data(3) := 0;
    Data(4) := 0;
    Data(5) := 1;
    Data(6) := 0;
    Data(7) := 0;
    Data(8) := 0;
    Data(9) := 0;
    Data(10) := 0;
    Data(11) := 0;
    Output_Lengths(Outputs_Range'First) := Length;
  end;

  procedure Run(Agent0: in out Agent.Agent;
                Agent1: in out Agent.Agent) is
  begin
    loop
      Agent.Run(Agent0, Processor'Access);
      Agent.Run(Agent1, Processor'Access);
    end loop;
  end;
end NF_Const;
