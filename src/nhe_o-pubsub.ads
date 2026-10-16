--  Formally verified Deterministic Ring-Buffer Pub/Sub Broker (BR-005)
pragma SPARK_Mode (On);

with Nhe_O.Types; use Nhe_O.Types;

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
      Ring    : Message_Ring  := [others => (others => <>)];
   end record;

   type Subscriber_Table is array (Subscriber_Id) of Subscriber_Slot;

   type PubSub_Broker is record
      Subscribers : Subscriber_Table := [others => (others => <>)];
   end record;

   --  Match exact channel or trailing '*' prefix wildcard (e.g. "events.*")
   function Matches_Channel
     (Pattern : Bounded_Ident;
      Channel : Bounded_Ident) return Boolean;

   --  SUBSCRIBE / PSUBSCRIBE: Register a channel or pattern subscription
   procedure Subscribe
     (Broker  : in out PubSub_Broker;
      Pattern : in     Bounded_Ident;
      Sub_Id  :    out Subscriber_Id;
      Status  :    out Engine_Status)
     with Pre  => Pattern.Length > 0,
          Post => (if Status = Status_Ok then Broker.Subscribers (Sub_Id).Active);

   --  UNSUBSCRIBE: Deactivate a subscriber slot and clear its queue
   procedure Unsubscribe
     (Broker : in out PubSub_Broker;
      Sub_Id : in     Subscriber_Id)
     with Post => not Broker.Subscribers (Sub_Id).Active
                  and then Broker.Subscribers (Sub_Id).Count = 0;

   --  PUBLISH / NOTIFY: Deliver payload to all matching active subscribers' ring buffers
   procedure Publish
     (Broker    : in out PubSub_Broker;
      Channel   : in     Bounded_Ident;
      Payload   : in     Bounded_Text;
      Delivered :    out Subscriber_Count)
     with Pre => Channel.Length > 0;

   --  Dequeue oldest FIFO message from subscriber's ring buffer
   procedure Poll_Message
     (Broker : in out PubSub_Broker;
      Sub_Id : in     Subscriber_Id;
      Msg    :    out PubSub_Message;
      Found  :    out Boolean)
     with Post => (if Found then
                     Broker.Subscribers (Sub_Id).Count =
                       Broker'Old.Subscribers (Sub_Id).Count - 1);

end Nhe_O.PubSub;
