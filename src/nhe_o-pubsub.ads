--  Formally verified Dual-Mode Ring-Buffer & Durable WAL Pub/Sub Broker
--  (BR-005, ADR-004, HIGH-07, MED-03)
pragma SPARK_Mode (On);

with Nhe_O.Types;       use Nhe_O.Types;
with Nhe_O.Transaction; use Nhe_O.Transaction;

package Nhe_O.PubSub is

   Max_Subscribers : constant := 16;
   subtype Subscriber_Id is Positive range 1 .. Max_Subscribers;
   subtype Subscriber_Count is Natural range 0 .. Max_Subscribers;

   Queue_Capacity : constant := 16;
   subtype Queue_Index is Positive range 1 .. Queue_Capacity;
   subtype Queue_Length is Natural range 0 .. Queue_Capacity;

   type PubSub_Message is record
      Channel : Bounded_Ident := (Length => 0, Data => [others => ' ']);
      Payload : Bounded_Text  := (Length => 0, Data => [others => ' ']);
   end record;

   type Message_Ring is array (Queue_Index) of PubSub_Message;

   type Subscriber_Slot is record
      Active  : Boolean       := False;
      Pattern : Bounded_Ident := (Length => 0, Data => [others => ' ']);
      Head    : Queue_Index   := 1;
      Tail    : Queue_Index   := 1;
      Count   : Queue_Length  := 0;
      Dropped : Natural       := 0;
      Ring    : Message_Ring  := [others => (others => <>)];
   end record;

   --  Ring-buffer structural invariant for a subscriber slot (MED-03)
   function Is_Valid_Subscriber_Ring (Slot : Subscriber_Slot) return Boolean is
     (((Slot.Head - 1 + Slot.Count) mod Queue_Capacity) + 1 = Slot.Tail);

   type Subscriber_Table is array (Subscriber_Id) of Subscriber_Slot;

   type PubSub_Broker is record
      Subscribers : Subscriber_Table := [others => (others => <>)];
   end record;

   -------------------------------------------------------------------------
   --  Transactional Durable Notification Staging (PostgreSQL LISTEN/NOTIFY)
   -------------------------------------------------------------------------

   Max_Staged_Notifications : constant := 16;
   subtype Staged_Notify_Index is Positive range 1 .. Max_Staged_Notifications;
   subtype Staged_Notify_Count is Natural range 0 .. Max_Staged_Notifications;

   type Staged_Notify_Array is array (Staged_Notify_Index) of PubSub_Message;

   type Tx_Notification_Buffer is record
      Owner_Tx : Valid_Tx_Id         := 1;
      Count    : Staged_Notify_Count := 0;
      Items    : Staged_Notify_Array := [others => (others => <>)];
   end record;

   --  Match exact channel or trailing '*' prefix wildcard (e.g. "events.*")
   function Matches_Channel
     (Pattern : Bounded_Ident;
      Channel : Bounded_Ident) return Boolean
     with Global => null;

   --  SUBSCRIBE / PSUBSCRIBE / LISTEN: Register a channel or pattern subscription
   procedure Subscribe
     (Broker  : in out PubSub_Broker;
      Pattern : in     Bounded_Ident;
      Sub_Id  :    out Subscriber_Id;
      Status  :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Pattern.Length > 0,
          Post   => (if Status = Status_Ok then
                       Broker.Subscribers (Sub_Id).Active
                       and then Is_Valid_Subscriber_Ring (Broker.Subscribers (Sub_Id)));

   --  UNSUBSCRIBE / UNLISTEN: Deactivate a subscriber slot and clear its queue
   procedure Unsubscribe
     (Broker : in out PubSub_Broker;
      Sub_Id : in     Subscriber_Id)
     with Global => null,
          Always_Terminates,
          Post   => not Broker.Subscribers (Sub_Id).Active
                    and then Broker.Subscribers (Sub_Id).Count = 0
                    and then Is_Valid_Subscriber_Ring (Broker.Subscribers (Sub_Id));

   --  Mode 1 (Redis PUBLISH): Immediate in-memory delivery to matching subscribers
   procedure Publish
     (Broker    : in out PubSub_Broker;
      Channel   : in     Bounded_Ident;
      Payload   : in     Bounded_Text;
      Delivered :    out Subscriber_Count)
     with Global => null,
          Always_Terminates,
          Pre    => Channel.Length > 0;

   --  Mode 1 with explicit overflow reporting (HIGH-07): reports both Delivered
   --  and Dropped subscriber counts when a matching subscriber's ring is full.
   procedure Publish
     (Broker    : in out PubSub_Broker;
      Channel   : in     Bounded_Ident;
      Payload   : in     Bounded_Text;
      Delivered :    out Subscriber_Count;
      Dropped   :    out Subscriber_Count)
     with Global => null,
          Always_Terminates,
          Pre    => Channel.Length > 0;

   --  Mode 2 (PostgreSQL NOTIFY — Durable): Stage a notification inside an active transaction
   --  held behind the WAL Commit Barrier until Commit_Tx succeeds (ADR-004 / BR-005 / HIGH-07)
   procedure Stage_Notify
     (Ctx     : in     Transaction_Context;
      Staging : in out Tx_Notification_Buffer;
      Channel : in     Bounded_Ident;
      Payload : in     Bounded_Text;
      Status  :    out Engine_Status)
     with Global => null,
          Always_Terminates,
          Pre    => Ctx.State = Tx_Active and then Channel.Length > 0,
          Post   => (if Status = Status_Ok then
                       Staging.Count = Staging.Count'Old + 1
                       and then Staging.Owner_Tx = Ctx.Id);

   --  Flush staged notifications across the WAL Commit Barrier ONLY after Tx_Committed
   --  and only when Staging.Owner_Tx matches Ctx.Id (HIGH-07)
   procedure Flush_Committed_Notifications
     (Ctx             : in     Transaction_Context;
      Staging         : in out Tx_Notification_Buffer;
      Broker          : in out PubSub_Broker;
      Total_Delivered :    out Natural)
     with Global => null,
          Always_Terminates,
          Pre    => Ctx.State = Tx_Committed,
          Post   => Staging.Count = 0;

   --  Discard staged notifications when a transaction rolls back or aborts (HIGH-07)
   procedure Discard_Staged_Notifications
     (Ctx     : in     Transaction_Context;
      Staging : in out Tx_Notification_Buffer)
     with Global => null,
          Always_Terminates,
          Pre    => Ctx.State = Tx_Aborted,
          Post   => Staging.Count = 0;

   --  Dequeue oldest FIFO message from subscriber's ring buffer
   procedure Poll_Message
     (Broker : in out PubSub_Broker;
      Sub_Id : in     Subscriber_Id;
      Msg    :    out PubSub_Message;
      Found  :    out Boolean)
     with Global => null,
          Always_Terminates,
          Post   => (if Found then
                       Broker.Subscribers (Sub_Id).Count =
                         Broker'Old.Subscribers (Sub_Id).Count - 1);

end Nhe_O.PubSub;
