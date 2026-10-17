pragma SPARK_Mode (On);

package body Nhe_O.PubSub is

   function Matches_Channel
     (Pattern : Bounded_Ident;
      Channel : Bounded_Ident) return Boolean
   is
      Prefix_Len : Natural;
   begin
      if Pattern.Length = 0 or else Channel.Length = 0 then
         return False;
      end if;

      --  Check for wildcard '*' at the end of Pattern
      if Pattern.Data (Pattern.Length) = '*' then
         Prefix_Len := Pattern.Length - 1;
         if Channel.Length < Prefix_Len then
            return False;
         end if;
         for I in 1 .. Prefix_Len loop
            pragma Loop_Invariant (I in 1 .. Prefix_Len);
            if Pattern.Data (I) /= Channel.Data (I) then
               return False;
            end if;
         end loop;
         return True;
      else
         return Equal_Ident (Pattern, Channel);
      end if;
   end Matches_Channel;

   procedure Subscribe
     (Broker  : in out PubSub_Broker;
      Pattern : in     Bounded_Ident;
      Sub_Id  :    out Subscriber_Id;
      Status  :    out Engine_Status)
   is
   begin
      Sub_Id := 1;
      for I in Subscriber_Id loop
         if not Broker.Subscribers (I).Active then
            Broker.Subscribers (I) := (
               Active  => True,
               Pattern => Pattern,
               Head    => 1,
               Tail    => 1,
               Count   => 0,
               Ring    => [others => (others => <>)]
            );
            Sub_Id := I;
            Status := Status_Ok;
            return;
         end if;
      end loop;
      Status := Status_Capacity_Exceeded;
   end Subscribe;

   procedure Unsubscribe
     (Broker : in out PubSub_Broker;
      Sub_Id : in     Subscriber_Id)
   is
   begin
      Broker.Subscribers (Sub_Id).Active := False;
      Broker.Subscribers (Sub_Id).Count  := 0;
      Broker.Subscribers (Sub_Id).Head   := 1;
      Broker.Subscribers (Sub_Id).Tail   := 1;
   end Unsubscribe;

   procedure Publish
     (Broker    : in out PubSub_Broker;
      Channel   : in     Bounded_Ident;
      Payload   : in     Bounded_Text;
      Delivered :    out Subscriber_Count)
   is
      Tail_Idx : Queue_Index;
   begin
      Delivered := 0;
      for I in Subscriber_Id loop
         pragma Loop_Invariant (Delivered <= I - 1);
         if Broker.Subscribers (I).Active
           and then Matches_Channel (Broker.Subscribers (I).Pattern, Channel)
           and then Broker.Subscribers (I).Count < Queue_Capacity
         then
            Tail_Idx := Broker.Subscribers (I).Tail;
            Broker.Subscribers (I).Ring (Tail_Idx) := (
               Channel => Channel,
               Payload => Payload
            );
            if Tail_Idx = Queue_Capacity then
               Broker.Subscribers (I).Tail := 1;
            else
               Broker.Subscribers (I).Tail := Tail_Idx + 1;
            end if;
            Broker.Subscribers (I).Count := Broker.Subscribers (I).Count + 1;
            Delivered := Delivered + 1;
         end if;
      end loop;
   end Publish;

   procedure Stage_Notify
     (Ctx     : in     Transaction_Context;
      Staging : in out Tx_Notification_Buffer;
      Channel : in     Bounded_Ident;
      Payload : in     Bounded_Text;
      Status  :    out Engine_Status)
   is
   begin
      if Staging.Count = Max_Staged_Notifications then
         Status := Status_Capacity_Exceeded;
         return;
      end if;

      Staging.Owner_Tx := Ctx.Id;
      Staging.Count    := Staging.Count + 1;
      Staging.Items (Staging.Count) := (
         Channel => Channel,
         Payload => Payload
      );
      Status := Status_Ok;
   end Stage_Notify;

   procedure Flush_Committed_Notifications
     (Ctx             : in     Transaction_Context;
      Staging         : in out Tx_Notification_Buffer;
      Broker          : in out PubSub_Broker;
      Total_Delivered :    out Natural)
   is
      pragma Unreferenced (Ctx);
      Step_Deliv : Subscriber_Count;
   begin
      Total_Delivered := 0;
      for I in 1 .. Staging.Count loop
         pragma Loop_Invariant (Total_Delivered <= (I - 1) * Max_Subscribers);
         if Staging.Items (I).Channel.Length > 0 then
            Publish
              (Broker    => Broker,
               Channel   => Staging.Items (I).Channel,
               Payload   => Staging.Items (I).Payload,
               Delivered => Step_Deliv);
            Total_Delivered := Total_Delivered + Step_Deliv;
         end if;
      end loop;

      Staging.Count := 0;
      Staging.Items := [others => (others => <>)];
   end Flush_Committed_Notifications;

   procedure Discard_Staged_Notifications
     (Ctx     : in     Transaction_Context;
      Staging : in out Tx_Notification_Buffer)
   is
      pragma Unreferenced (Ctx);
   begin
      Staging.Count := 0;
      Staging.Items := [others => (others => <>)];
   end Discard_Staged_Notifications;

   procedure Poll_Message
     (Broker : in out PubSub_Broker;
      Sub_Id : in     Subscriber_Id;
      Msg    :    out PubSub_Message;
      Found  :    out Boolean)
   is
      Head_Idx : Queue_Index;
   begin
      Msg   := (others => <>);
      Found := False;

      if not Broker.Subscribers (Sub_Id).Active
        or else Broker.Subscribers (Sub_Id).Count = 0
      then
         return;
      end if;

      Head_Idx := Broker.Subscribers (Sub_Id).Head;
      Msg      := Broker.Subscribers (Sub_Id).Ring (Head_Idx);
      if Head_Idx = Queue_Capacity then
         Broker.Subscribers (Sub_Id).Head := 1;
      else
         Broker.Subscribers (Sub_Id).Head := Head_Idx + 1;
      end if;
      Broker.Subscribers (Sub_Id).Count := Broker.Subscribers (Sub_Id).Count - 1;
      Found := True;
   end Poll_Message;

end Nhe_O.PubSub;

