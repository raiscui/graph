module Graph
    ( NodeId
    , Node
    , Edge
    , Adjacency
    , NodeContext
    , Decomposition
    , Graph

    , empty
    , isEmpty
    , insert
    , focus
    , focusAny
    , nodeRange

    , nodeIds
    , nodes
    , edges
    , fromNodesAndEdges

    , fold
    , mapContexts
    , mapNodes
    , mapEdges
    
    ) where
    

import IntDict as IntDict exposing (IntDict)
import Maybe as Maybe exposing (Maybe)
import Lazy as Lazy exposing (Lazy)
    
type alias NodeId = Int

type alias Node n =
    { id : NodeId
    , label : n
    }

type alias Edge e =
    { from : NodeId
    , to : NodeId
    , label : e 
    }

type alias Adjacency e = IntDict e

type alias NodeContext n e =
    { node : Node n
    , incoming : Adjacency e
    , outgoing : Adjacency e
    }

type alias Decomposition n e =
    { focused : NodeContext n e
    , rest : Lazy (Graph n e)
    }

-- We will only have the Patricia trie based DynGraph implementation for simplicity.
-- Also, there is no real practical reason to separate that or to allow other implementations
-- which would justify the complexity.

type alias GraphRep n e = IntDict (NodeContext n e)
type Graph n e = Graph (GraphRep n e)

empty : Graph n e
empty = Graph IntDict.empty

isEmpty : Graph n e -> Bool
isEmpty graph = 
    case graph of
      Graph rep -> IntDict.isEmpty rep

type alias Lens s a = 
    { get : s -> a
    , set : s -> a -> s
    }

composeLens : Lens a b -> Lens b c -> Lens a c
composeLens outer inner =
    { get = outer.get >> inner.get
    , set a = inner.set (outer.get a) >> outer.set a
    } 

incoming_ : Lens (NodeContext n e) (Adjacency e)
incoming_ =
    { get = .incoming
    , set context map = { context | incoming <- map }
    }
          
outgoing_ : Lens (NodeContext n e) (Adjacency e)
outgoing_ =
    { get = .outgoing
    , set context map = { context | outgoing <- map }
    }


-- This lens would benefit from a combined modify/update representation instead of split getter and setter
lookup_ : NodeId -> Lens (IntDict v) (Maybe v)
lookup_ id =
    { get = IntDict.get id
    , set dict v = IntDict.update id (always v) dict
    }                       

incomingEdgeLens : NodeId -> Lens (NodeContext n e) (Maybe e)
incomingEdgeLens id = incoming_ `composeLens` lookup_ id 

outgoingEdgeLens : NodeId -> Lens (NodeContext n e) (Maybe e)
outgoingEdgeLens id = outgoing_ `composeLens` lookup_ id


updateAdjajency : Bool -> NodeContext n e -> GraphRep n e -> GraphRep n e
updateAdjajency shallInsert updateContext rep =                                
    let updateNeighbor edgeLens edge ctx =
            edgeLens.set ctx (if shallInsert then Just edge else Nothing)
        updateNeighbors edgeLens nodeId edge =
            IntDict.update nodeId (Maybe.map (updateNeighbor edgeLens edge))
        -- This essentially iterates over the keys of updateContext.outgoing to delete the corresponding incoming edges
        rep1 = IntDict.foldl (updateNeighbors (outgoingEdgeLens updateContext.node.id)) rep updateContext.outgoing
        rep2 = IntDict.foldl (updateNeighbors (incomingEdgeLens updateContext.node.id)) rep1 updateContext.incoming
    in if shallInsert
       then IntDict.insert updateContext.node.id updateContext rep2
       else IntDict.remove updateContext.node.id rep2

insertNode : NodeContext n e -> GraphRep n e -> GraphRep n e
insertNode = updateAdjajency True

insert : NodeContext n e -> Graph n e -> Graph n e
insert nodeContext graph =
    -- We remove the node with the same id from graph, if present
    let graph' = Maybe.withDefault graph (Maybe.map (.rest >> Lazy.force) (focus nodeContext.node.id graph))
    in case graph' of
      Graph rep -> Graph (insertNode nodeContext rep)

deleteNode : NodeContext n e -> GraphRep n e -> GraphRep n e
deleteNode = updateAdjajency False

focus : NodeId -> Graph n e -> Maybe (Decomposition n e)
focus node graph =
    case graph of
      Graph rep ->
          let decompose nodeContext =
                  { focused = nodeContext
                  , rest = Lazy.lazy (\_ -> Graph (deleteNode nodeContext rep))
                  }
          in Maybe.map decompose (IntDict.get node rep)


focusAny : Graph n e -> Maybe (Decomposition n e)
focusAny graph =
    case graph of
        Graph rep ->
            IntDict.findMin rep `Maybe.andThen` \(nodeId, _) ->
            focus nodeId graph


nodeRange : Graph n e -> Maybe (NodeId, NodeId)
nodeRange graph =
    case graph of
        Graph rep ->
            IntDict.findMin rep `Maybe.andThen` \(min, _) ->
            IntDict.findMax rep `Maybe.andThen` \(max, _) ->
            Just (min, max)
            

member : NodeId -> Graph n e -> Bool
member id graph =
    case graph of
        Graph rep -> IntDict.member id rep
            

nodes : Graph n e -> List (Node n)
nodes graph =
    case graph of
      Graph rep -> List.map .node (IntDict.values rep)

nodeIds : Graph n e -> List (NodeId)
nodeIds graph =
    case graph of
      Graph rep -> IntDict.keys rep

edges : Graph n e -> List (Edge e)
edges graph =
    let foldl' f dict list = IntDict.foldl f list dict -- so that we can use pointfree notation
        prependEdges node1 ctx =
             foldl' (\node2 e -> (::) { to = node2, from = node1, label = e }) ctx.outgoing 
    in case graph of
         Graph rep ->
             foldl' prependEdges rep []
    
fromNodesAndEdges : List (Node n) -> List (Edge e) -> Graph n e
fromNodesAndEdges nodes edges = 
    let nodeRep = List.foldl (\n rep -> IntDict.insert n.id { node = n, outgoing = IntDict.empty, incoming = IntDict.empty } rep) IntDict.empty nodes
        addEdge edge rep =
            let updateOutgoing ctx =
                    { ctx | outgoing <- IntDict.insert edge.to edge.label ctx.outgoing }
                updateIncoming ctx =
                    { ctx | incoming <- IntDict.insert edge.from edge.label ctx.incoming }
            in rep
                |> IntDict.update edge.from (Maybe.map updateOutgoing)
                |> IntDict.update edge.to (Maybe.map updateIncoming)
    in Graph (List.foldl addEdge nodeRep edges)
        

-- TRANSFORMS


fold : (NodeContext n e -> acc -> acc) -> acc -> Graph n e -> acc
fold f acc graph =
    case focusAny graph of
        Just decomp -> fold f (f decomp.focused acc) (Lazy.force decomp.rest) 
        Nothing -> acc


mapContexts : (NodeContext n1 e1 -> NodeContext n2 e2) -> Graph n1 e1 -> Graph n2 e2
mapContexts f = fold (\ctx -> insert (f ctx)) empty


mapNodes : (n1 -> n2) -> Graph n1 e -> Graph n2 e
mapNodes f = fold (\ctx -> insert { ctx | node <- { id = ctx.node.id, label = f ctx.node.label } }) empty

             
mapEdges : (e1 -> e2) -> Graph n e1 -> Graph n e2
mapEdges f =
    fold (\ctx -> insert
                  { ctx
                  | outgoing <- IntDict.map (\n e -> f e) ctx.outgoing
                  , incoming <- IntDict.map (\n e -> f e) ctx.incoming })
         empty