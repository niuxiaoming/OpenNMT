print(" * Refactoring the decoder code for sampling - 4/4/2017")

--[[ Unit to decode a sequence of output tokens.

     .      .      .             .
     |      |      |             |
    h_1 => h_2 => h_3 => ... => h_n
     |      |      |             |
     .      .      .             .
     |      |      |             |
    h_1 => h_2 => h_3 => ... => h_n
     |      |      |             |
     |      |      |             |
    x_1    x_2    x_3           x_n

Inherits from [onmt.Sequencer](onmt+modules+Sequencer).

--]]
local Decoder, parent = torch.class('onmt.Decoder', 'onmt.Sequencer')


--[[ Construct a decoder layer.

Parameters:

  * `inputNetwork` - input nn module.
  * `rnn` - recurrent module, such as [onmt.LSTM](onmt+modules+LSTM).
  * `generator` - optional, an output [onmt.Generator](onmt+modules+Generator).
  * `inputFeed` - bool, enable input feeding.
--]]
function Decoder:__init(inputNetwork, rnn, generator, attention, inputFeed, coverage)
  self.rnn = rnn
  self.inputNet = inputNetwork

  self.args = {}
  self.args.rnnSize = self.rnn.outputSize
  self.args.numEffectiveLayers = self.rnn.numEffectiveLayers

  self.args.inputIndex = {}
  self.args.outputIndex = {}

  -- Input feeding means the decoder takes an extra
  -- vector each time representing the attention at the
  -- previous step.
  self.args.inputFeed = inputFeed
  self.args.coverageSize = coverage
  self.args.softmaxSize = generator.outputSize
  
  -- backward compatibility with older models
  if self.args.coverageSize == nil then 
		self.args.coverageSize = 0
	end
	
	if self.args.attention == nil then
		self.args.attention = 'global'
	end
  
  
  -- Attention type
  self.args.attention = attention
  
  -- The generator use the output of the decoder sequencer to generate the
  -- likelihoods over the target vocabulary.
  self.generator = generator

  parent.__init(self, self:_buildModel())
  
  self:resetPreallocation()
  
  self:disableSampling()
  
  self.args.nSamplingSteps = 0 -- default: don't sample anything
  self.args.maxLength = onmt.Constants.MAX_TARGET_LENGTH 
end

--[[ Return a new Decoder using the serialized data `pretrained`. ]]
function Decoder.load(pretrained)
  local self = torch.factory('onmt.Decoder')()

  self.args = pretrained.args

  parent.__init(self, pretrained.modules[1])
  --~ self.generator = pretrained.modules[2]
  self:add(self.generator)

  self:resetPreallocation()

  return self
end

--[[ Return data to serialize. ]]
function Decoder:serialize()
  return {
    modules = self.modules,
    args = self.args
  }
end

function Decoder:resetPreallocation()
  if self.args.inputFeed then
    self.inputFeedProto = torch.Tensor()
  end
  
  -- backward compatibility with older models
  if self.args.coverageSize == nil then
		self.args.coverageSize = 0
	end
  
  if self.args.coverageSize > 0 then
		self.coverageInputProto = torch.Tensor()
		self.gradCoverageProto = torch.Tensor()
  end

  -- Prototype for preallocated hidden and cell states.
  self.stateProto = torch.Tensor()

  -- Prototype for preallocated output gradients.
  self.gradOutputProto = torch.Tensor()

  -- Prototype for preallocated context gradient.
  self.gradContextProto = torch.Tensor()
  
  self.gradHiddenProto = torch.Tensor()
  
  self.samplingProto = torch.Tensor()
  
  self.gradSamplingProto = torch.Tensor()
  
  self.gradRewardProto = torch.Tensor()
  
  self.sampledSequence = torch.Tensor()
  
  self.gradSoftMaxProto = torch.Tensor()
  
  self.continue = torch.Tensor()
end

--[[ Build a default one time-step of the decoder

Returns: An nn-graph mapping

  $${(c^1_{t-1}, h^1_{t-1}, .., c^L_{t-1}, h^L_{t-1}, x_t, con/H, if) =>
  (c^1_{t}, h^1_{t}, .., c^L_{t}, h^L_{t}, a)}$$

  Where ${c^l}$ and ${h^l}$ are the hidden and cell states at each layer,
  ${x_t}$ is a sparse word to lookup,
  ${con/H}$ is the context/source hidden states for attention,
  ${if}$ is the input feeding, and
  ${a}$ is the context vector computed at this timestep.
--]]
function Decoder:_buildModel()
  local inputs = {}
  local states = {}

  -- Inputs are previous layers first.
  for _ = 1, self.args.numEffectiveLayers do
    local h0 = nn.Identity()() -- batchSize x rnnSize
    table.insert(inputs, h0)
    table.insert(states, h0)
  end

  local x = nn.Identity()() -- batchSize
  table.insert(inputs, x)
  self.args.inputIndex.x = #inputs

  local context = nn.Identity()() -- batchSize x sourceLength x rnnSize
  table.insert(inputs, context)
  self.args.inputIndex.context = #inputs
  
  local inputFeed
  if self.args.inputFeed then
    inputFeed = nn.Identity()() -- batchSize x rnnSize
    table.insert(inputs, inputFeed)
    self.args.inputIndex.inputFeed = #inputs
  end
  
  local coverageVector
  if self.args.coverageSize > 0 then
	_G.logger:info(" * Maintaining context coverage with GRU-based model ")
	coverageVector = nn.Identity()() -- batchSize x coverageSize
	table.insert(inputs, coverageVector)
	self.args.inputIndex.coverage = #inputs
  end

  -- Compute the input network.
  local embedding = self.inputNet(x)
  
  
  local input = embedding
  -- If set, concatenate previous decoder output.
  if self.args.inputFeed then
    input = nn.JoinTable(2)({input, inputFeed})
  end
  table.insert(states, input)

  -- Forward states and input into the RNN.
  local outputs = self.rnn(states)

  -- The output of a subgraph is a node: split it to access the last RNN output.
  outputs = { outputs:split(self.args.numEffectiveLayers) }

  -- Compute the attention here using h^L as query.
  
  local attnLayer
  
  if self.args.coverageSize == 0 then
	  attnLayer = onmt.GlobalAttention(self.args.rnnSize, self.args.attention == 'cgate')
  else
	  attnLayer = onmt.CoverageAttention(self.args.rnnSize, self.args.coverageSize)
  end
  
  attnLayer.name = 'decoderAttn'
  
  -- prepare input for the attention module
  local attnInput = {outputs[#outputs], context}
  if self.args.coverageSize > 0 then
	table.insert(attnInput, coverageVector)
  end
  
  local attnOutput = attnLayer(attnInput)
  
  
  local nextCoverage
  if self.args.coverageSize > 0 then
	attnOutput = {attnOutput:split(2)}
	nextCoverage = attnOutput[2]
	attnOutput = attnOutput[1]
	table.insert(outputs, nextCoverage)
	self.args.outputIndex.coverage = #outputs
  end
  
  if self.rnn.dropout > 0 then
    attnOutput = nn.Dropout(self.rnn.dropout)(attnOutput)
  end
  table.insert(outputs, attnOutput)
  self.args.outputIndex.hidden = #outputs
  
  local prediction = self.generator(attnOutput)
  table.insert(outputs, prediction)
  self.args.outputIndex.prediction = #outputs
  
  -- Sampling from softmax
  local sampler = nn.MultinomialSample()
  local sample = sampler(prediction)
  table.insert(outputs, sample)
  self.args.outputIndex.sample = #outputs 
  
  local baselineRewarder = onmt.BaselineRewarder(self.args.rnnSize)
  local predReward = baselineRewarder(attnOutput)
  table.insert(outputs, predReward)
  self.args.outputIndex.reward = #outputs
  
  local network = nn.gModule(inputs, outputs)
  -- Pointers to the layers 
  network.generator = self.generator
  network.decoderAttn = attnLayer
  network.decoderSampler = sampler
  
  
  return network
end

function Decoder:findAttentionModel()
	if not self.decoderAttn then
		self.network:apply(function (layer)
			if layer.name == 'decoderAttn' then
				self.decoderAttn = layer
			elseif layer.name == 'softmaxAttn' then
				self.softmaxAttn = layer
			end
		end)
		self.decoderAttnClones = {}
	end
	
	for t = #self.decoderAttnClones+1, #self.networkClones do
		self:net(t):apply(function (layer)
			if layer.name == 'decoderAttn' then
				self.decoderAttnClones[t] = layer
			elseif layer.name == 'softmaxAttn' then
				self.decoderAttnClones[t].softmaxAttn = layer
			end
		end)
	end
end

--[[ Mask padding means that the attention-layer is constrained to
  give zero-weight to padding. This is done by storing a reference
  to the softmax attention-layer.

  Parameters:

  * See  [onmt.MaskedSoftmax](onmt+modules+MaskedSoftmax).
--]]
function Decoder:maskPadding(sourceSizes, sourceLength)
	self:findAttentionModel()
	
	local function substituteSoftmax(module)
		if module.name == 'softmaxAttn' then
			local mod
			if sourceSizes ~= nil then
				mod = onmt.MaskedSoftmax(sourceSizes, sourceLength)
			else
				mod = nn.SoftMax()
			end
			mod.name = 'softmaxAttn'
			mod:type(module._type)
			self.softmaxAttn = mod
			return mod
		else
			return module
		end
	end
	
	self.decoderAttn:replace(substituteSoftmax)
	for t = 1, #self.networkClones do
		self.decoderAttnClones[t]:replace(substituteSoftmax)
	end
end
--~ function Decoder:maskPadding(sourceSizes, sourceLength)
  --~ if not self.decoderAttn then
    --~ self.network:apply(function (layer)
      --~ if layer.name == 'decoderAttn' then
        --~ self.decoderAttn = layer
      --~ end
    --~ end)
  --~ end
--~ 
  --~ self.decoderAttn:replace(function(module)
    --~ if module.name == 'softmaxAttn' then
      --~ local mod
      --~ if sourceSizes ~= nil then
        --~ mod = onmt.MaskedSoftmax(sourceSizes, sourceLength)
      --~ else
        --~ mod = nn.SoftMax()
      --~ end
--~ 
      --~ mod.name = 'softmaxAttn'
      --~ mod:type(module._type)
      --~ self.softmaxAttn = mod
      --~ return mod
    --~ else
      --~ return module
    --~ end
  --~ end)
--~ end

--[[ Run one step of the decoder.

Parameters:

  * `input` - input to be passed to inputNetwork.
  * `prevStates` - stack of hidden states (batch x layers*model x rnnSize)
  * `context` - encoder output (batch x n x rnnSize)
  * `prevOut` - previous distribution (batch x #words)
  * `t` - current timestep

Returns:

 1. `out` - Top-layer hidden state.
 2. `states` - All states.
--]]
--~ function Decoder:forwardOne(input, prevStates, context, prevOut, prevCoverage, t)
function Decoder:forwardOne(input, prevStates, context, prevOutputs, t)
  local inputs = {}
  
  local prevHidden = prevOutputs[1]
  local prevCoverage = prevOutputs[2] -- could be nil if coverage is disabled

  -- Create RNN input (see sequencer.lua `buildNetwork('dec')`).
  onmt.utils.Table.append(inputs, prevStates)
  table.insert(inputs, input)
  table.insert(inputs, context)
  local inputSize
  if torch.type(input) == 'table' then
    inputSize = input[1]:size(1)
  else
    inputSize = input:size(1)
  end

  if self.args.inputFeed then
    if prevHidden == nil then
      table.insert(inputs, onmt.utils.Tensor.reuseTensor(self.inputFeedProto,
                                                         { inputSize, self.args.rnnSize }))
    else
      table.insert(inputs, prevHidden)
    end
  end
  
  if self.args.coverageSize > 0 then
	if prevCoverage == nil then -- initialize the coverage vector as zero
		prevCoverage = onmt.utils.Tensor.reuseTensor(self.coverageInputProto, {inputSize, context:size(2), self.args.coverageSize})
	end
	table.insert(inputs, prevCoverage)
  end

  -- Remember inputs for the backward pass.
  if self.train then
    self.inputs[t] = inputs
  end
    
  local outputs = self:net(t):forward(inputs)

  -- Make sure decoder always returns table.
  if type(outputs) ~= "table" then outputs = { outputs } end
--~ 
  local finalHidden = outputs[self.args.outputIndex.hidden]
  local prediction = outputs[self.args.outputIndex.prediction]
  local sample = outputs[self.args.outputIndex.sample]
  local reward = outputs[self.args.outputIndex.reward]
  local states = {}
  
  local nextCoverage = nil
  if self.args.coverageSize > 0 then
	nextCoverage = outputs[self.args.outputIndex.coverage] -- update the coverage vector
  end
  
  for i = 1, self.args.numEffectiveLayers do
    table.insert(states, outputs[i])
  end
  
  local nextOutputs = {}
  
  nextOutputs[1] = finalHidden
  nextOutputs[2] = nextCoverage
  nextOutputs[3] = prediction
  nextOutputs[4] = sample
  nextOutputs[5] = reward

  --~ return out, nextCoverage, states
  return nextOutputs, states
end

--[[Compute all forward steps.

  Parameters:

  * `batch` - `Batch` object
  * `encoderStates` -
  * `context` -
  * `func` - Calls `func(out, t)` each timestep.
--]]

function Decoder:forwardAndApply(batch, encoderStates, context, func)
  -- TODO: Make this a private method.

  if self.statesProto == nil then
    self.statesProto = onmt.utils.Tensor.initTensorTable(#encoderStates,
                                                         self.stateProto,
                                                         { batch.size, self.args.rnnSize })
  end

  local states = onmt.utils.Tensor.copyTensorTable(self.statesProto, encoderStates)

  local prevOutputs = {}

  for t = 1, batch.targetLength do
    prevOutputs, states = self:forwardOne(batch:getTargetInput(t), states, context, prevOutputs, t)
    func(prevOutputs, t)
  end
end

--[[Compute all forward steps.

  Parameters:

  * `batch` - a `Batch` object.
  * `encoderStates` - a batch of initial decoder states (optional) [0]
  * `context` - the context to apply attention to.

  Returns: Table of top hidden state for each timestep.
--]]
function Decoder:forward(batch, encoderStates, context)
  encoderStates = encoderStates
    or onmt.utils.Tensor.initTensorTable(self.args.numEffectiveLayers,
                                         onmt.utils.Cuda.convert(torch.Tensor()),
                                         { batch.size, self.args.rnnSize })
  if self.train then
    self.inputs = {}
    self.sampledSequence:resize(self.args.maxLength, batch.size):zero()
    self.predRewards = self.sampledSequence:clone()
  end

  local outputs = {}
  
  if self.statesProto == nil then
    self.statesProto = onmt.utils.Tensor.initTensorTable(#encoderStates,
                                                         self.stateProto,
                                                         { batch.size, self.args.rnnSize })
  end

  local states = onmt.utils.Tensor.copyTensorTable(self.statesProto, encoderStates)

  local prevOutputs = {}
  
  --~ self.nstepsinit = math.max(batch.targetLength - self.args.nSamplingSteps, 1)
  
  -- It is unfortunate that we are dealing with variable size sequences
  -- 
  local skips = batch.targetSize:clone() - self.args.nSamplingSteps
  
  -- minimum nsteps: 1
  skips[torch.lt(skips, 1)] = 1
  
  
  self.nstepsinit = torch.min(skips)
  
  local maxSkip = torch.max(skips)
  
  if maxSkip >= batch.targetLength then
	self.nstepsinit = maxSkip + 1
  end
  
  
  self:disableSampling()
  --~ self:enableSampling()
  local realLength = self.args.maxLength
  -- we have to loop until the maximum length of sampling
  for t = 1, self.args.maxLength do
	local inputT 
	
	if t > 1 then
		inputT = self.sampledSequence[t-1]
	else
		inputT = batch:getTargetInput(1)
	end
	
	-- start sampling from the step of stepsinit 
	if t >= self.nstepsinit then
		self:enableSampling(t)
	end
	
	 
	-- do a forward pass over the model
	prevOutputs, states = self:forwardOne(inputT, states, context, prevOutputs, t)
	
	-- accumulate reinforcement samples and rewards from nstepsinit + 1
	if t >= self.nstepsinit then
		self.sampledSequence[t]:copy(prevOutputs[4]) 
		if t > self.nstepsinit then
			self.predRewards[t]:copy(prevOutputs[5][{{}, 1}])
		end
	else
		self.sampledSequence[t]:copy(batch:getTargetOutput(t)[1]) -- using ground truth as samples
	end
	
	table.insert(outputs, prevOutputs)
	
	if t > 1 then
		--~ if t >= batch.targetLength then
			--~ realLength = t
			--~ break
		--~ end
		
		-- first, we find the positions in the input that has EOS and PAD
		local compare = torch.eq(inputT, onmt.Constants.EOS)
		compare:add(torch.eq(inputT, onmt.Constants.PAD))
		-- and force the sampled positions to be PAD
		self.sampledSequence[t][compare]:fill(onmt.Constants.PAD)
		
		-- check the positions of the samples that are PAD or EOS -> that sentence is finished
		local stop = torch.eq(self.sampledSequence[t], onmt.Constants.EOS)
		stop:add(torch.eq(self.sampledSequence[t], onmt.Constants.PAD))
		--~ continue = continue:float()
		--~ print(continue)
		-- if all of them are finished then we stop the RNN from running
		if stop:sum() == batch.size then
			realLength = t
			break
		end
	end
	
	--~ if t > 1 then
		--~ local continue = torch.Tensor(batch.size) -- track completeness of each sentence
		--~ for b = 1, batch.size do
			--~ if inputT[b] == onmt.Constants.EOS or inputT[b] == onmt.Constants.PAD then -- stop sampling if input is EOS or PAD
				--~ self.sampledSequence[t][b] = onmt.Constants.PAD
			--~ end
			
			--~ if self.sampledSequence[t][b] == onmt.Constants.EOS or self.sampledSequence[t][b] == onmt.Constants.PAD then
				--~ continue[b] = 0 -- this sentence is finished
			--~ else
				--~ continue[b] = 1
			--~ end
		--~ end
		
		--~ if continue:sum() == 0 then -- if all sentences are finished
			--~ realLength = t 
			--~ break
		--~ end
		
	--~ end

	

	-- for the sentences with only one word (<s>)
	if batch.targetLength == 1 then
		realLength = t
		break
	end
	
	
	
	
  end
	
	--~ print(realLength)
	self.sampledSequence:resize(realLength, batch.size)
	--~ self.sampledSequence = self.sampledSequence:narrow(1, 1, realLength)
	--~ self.predRewards = self.predRewards:narrow(1, 1,realLength)
	self.predRewards:resize(realLength, batch.size)
  
	if torch.typename(self.sampledSequence):find('torch%.Cuda.*Tensor') then
		self.sampledSequence = self.sampledSequence:cuda()
	else
		self.sampledSequence = self.sampledSequence:float()
	end

  return outputs
end

--[[ Initialize the list of grad outputs.

Parameters:

  * `batch` - a `Batch` object

  Note: A list of grad outputs corresponding the outputs of the model:
  - final hidden layer (for input feeding)
  - coverage vector
  - prediction (softmax output)
		And the grad allocation for the context 
  -- ]]
function Decoder:initGradOutput(batch)
	if self.gradOutputsProto == nil then
		self.gradOutputsProto = onmt.utils.Tensor.initTensorTable(self.args.numEffectiveLayers,
															  self.gradOutputProto,
															  { batch.size, self.args.rnnSize })
	end

	local gradStatesInput = onmt.utils.Tensor.reuseTensorTable(self.gradOutputsProto,
															 { batch.size, self.args.rnnSize })
	local gradContextInput = onmt.utils.Tensor.reuseTensor(self.gradContextProto,
														 { batch.size, batch.sourceLength, self.args.rnnSize })
														 
	if self.args.coverageSize > 0 then
		local gradCoverageOutput = onmt.utils.Tensor.reuseTensor(self.gradCoverageProto, {batch.size, batch.sourceLength, self.args.coverageSize})
		table.insert(gradStatesInput, gradCoverageOutput)
	end

	local gradHiddenProto = onmt.utils.Tensor.reuseTensor(self.gradHiddenProto, {batch.size, self.args.rnnSize})
	table.insert(gradStatesInput, gradHiddenProto)
	
	gradStatesInput[self.args.outputIndex.prediction] = {}
	
	-- gradients w.r.t samples
	gradStatesInput[self.args.outputIndex.sample] = onmt.utils.Tensor.reuseTensor(self.gradSamplingProto, {batch.size})
	
	-- gradients w.r.t predicted rewards (always 0 in MIXER)
	gradStatesInput[self.args.outputIndex.reward] = onmt.utils.Tensor.reuseTensor(self.gradRewardProto, {batch.size, 1})
	
	self.gradSoftmaxProto = onmt.utils.Tensor.reuseTensor(self.gradSoftMaxProto, {batch.size, self.args.softmaxSize})
	
	return  gradStatesInput, gradContextInput
end

--[[ Compute the backward update.

Parameters:

  * `batch` - a `Batch` object
  * `outputs` - expected outputs
  * `criterion` - a single target criterion object

  Note: This code runs both the standard backward and criterion forward/backward.
  It returns both the gradInputs and the loss.
  -- ]]
function Decoder:backward(batch, outputs, criterion, criterionRF)
  
  
  local gradStatesInput, gradContextInput = self:initGradOutput(batch)
  

  local lossXENT = 0
  local lossRF   = 0
  local numSamplesXENT = 0
  local numSamplesRF   = 0
  local gradReinforce
  local totCumRewardPredError = 0
  
  local seqLength = self.sampledSequence:size(1)
  local nstepsinit = self.nstepsinit
  
  criterionRF:setSkips(nstepsinit)
  
  -- we only compute reinforce loss if we actually sampled
  if seqLength > nstepsinit then
	lossRF, numSamplesRF = criterionRF:forward({self.sampledSequence, self.predRewards}, batch.targetOutput)
	gradReinforce = criterionRF:backward({self.sampledSequence, self.predRewards}, batch.targetOutput)
	totCumRewardPredError = gradReinforce[2][nstepsinit+1]:norm()
	print("DEBUGGING")
  end
  
  --~ for t = batch.targetLength, 1, -1 do
  for t = seqLength, 1, -1 do
    -- Compute decoder output gradients.
    -- Note: This would typically be in the forward pass.
    --~ local pred = self.generator:forward(outputs[t])
	

    local pred = outputs[t][3]
    
    if t > nstepsinit then -- this is a reinforce step
		
		-- we don't use softmax here, so it will be zero
		gradStatesInput[self.args.outputIndex.prediction][1] =  self.gradSoftmaxProto
		
		gradStatesInput[self.args.outputIndex.reward][{{}, 1}]:copy(gradReinforce[2][t])
		
		gradStatesInput[self.args.outputIndex.sample] = gradReinforce[1][t]
		
    else -- this is an xent step, so nothing change
		--~ local output = batch:getTargetOutput(t)
		local output = {self.sampledSequence[t]}
		
		lossXENT = lossXENT + criterion:forward(pred, output)

		-- Compute the criterion gradient.
		local genGradOut = criterion:backward(pred, output)
		for j = 1, #genGradOut do
		  genGradOut[j]:div(batch.totalSize)
		end
		
		local count = output[1]:ne(onmt.Constants.PAD):sum()
		numSamplesXENT = numSamplesXENT + count
		
		-- Compute the final layer gradient.
		gradStatesInput[self.args.outputIndex.prediction] = genGradOut
    end

    -- Compute the standard backward.
    local gradInput = self:net(t):backward(self.inputs[t], gradStatesInput)

    -- Accumulate encoder output gradients.
    gradContextInput:add(gradInput[self.args.inputIndex.context])
    
    -- Reset the gradients for these guys
    gradStatesInput[self.args.outputIndex.hidden]:zero()
    gradStatesInput[self.args.outputIndex.sample]:zero()
    gradStatesInput[self.args.outputIndex.reward]:zero()
    
    if self.args.coverageSize > 0 then
		gradStatesInput[self.args.outputIndex.coverage]:zero()
	end

    -- Accumulate previous output gradients with input feeding gradients.
    if self.args.inputFeed and t > 1 then
      gradStatesInput[self.args.outputIndex.hidden] = gradInput[self.args.inputIndex.inputFeed]
    end
    
    -- Accumulate previous coverage gradients
    if self.args.coverageSize > 0 and t > 1 then
	  gradStatesInput[self.args.outputIndex.coverage] = gradInput[self.args.inputIndex.coverage]
    end

    -- Prepare next decoder output gradients.
    for i = 1, #self.statesProto do
      gradStatesInput[i]:copy(gradInput[i])
    end
  end
  
  local gradEncoderOutput = {}
  
  -- only return to the encoder the RNN states
  for i = 1, #self.statesProto do
	table.insert(gradEncoderOutput, gradStatesInput[i])
  end
  
  self.sampledSequence:set()
  self.predRewards:set()
  
  
  return gradEncoderOutput, gradContextInput, lossXENT, lossRF, numSamplesXENT, numSamplesRF, totCumRewardPredError
end


--[[ Compute the loss on a batch.

Parameters:

  * `batch` - a `Batch` to score.
  * `encoderStates` - initialization of decoder.
  * `context` - the attention context.
  * `criterion` - a pointwise criterion.

--]]
function Decoder:computeLoss(batch, encoderStates, context, criterion)
  encoderStates = encoderStates
    or onmt.utils.Tensor.initTensorTable(self.args.numEffectiveLayers,
                                         onmt.utils.Cuda.convert(torch.Tensor()),
                                         { batch.size, self.args.rnnSize })

  local loss = 0
  self:forwardAndApply(batch, encoderStates, context, function (out, t)
    --~ local pred = self.generator:forward(out[1])
    local pred = out[3]
    local output = batch:getTargetOutput(t)
    loss = loss + criterion:forward(pred, output)
  end)

  return loss
end


--[[ Compute the score of a batch.

Parameters:

  * `batch` - a `Batch` to score.
  * `encoderStates` - initialization of decoder.
  * `context` - the attention context.

--]]
function Decoder:computeScore(batch, encoderStates, context)
  encoderStates = encoderStates
    or onmt.utils.Tensor.initTensorTable(self.args.numEffectiveLayers,
                                         onmt.utils.Cuda.convert(torch.Tensor()),
                                         { batch.size, self.args.rnnSize })

  local score = {}

  self:forwardAndApply(batch, encoderStates, context, function (out, t)
    --~ local pred = self.generator:forward(out[1])
    local pred = out[3]
    for b = 1, batch.size do
      if t <= batch.targetSize[b] then
        score[b] = (score[b] or 0) + pred[1][b][batch.targetOutput[t][b]]
      end
    end
  end)

  return score
end


-- Sampling function
-- Input: batch, outputs from encoder (encoderStates, context) and max sample length
-- Note that here we don't use the sampling output, but to take argmax of the softmax
function Decoder:sampleBatch(batch, encoderStates, context, maxLength)
	
	maxLength = maxLength or onmt.Constants.MAX_TARGET_LENGTH
	
	local sampled = onmt.utils.Tensor.reuseTensor(self.samplingProto, {maxLength, batch.size})
	
	local sampledSeq = onmt.utils.Cuda.convert(sampled)

	sampledSeq:fill(onmt.Constants.PAD) -- fill with PAD first
	sampledSeq[1]:fill(onmt.Constants.BOS) -- <s> at the beginning
	
	if self.statesProto == nil then
		self.statesProto = onmt.utils.Tensor.initTensorTable(#encoderStates,
                                                         self.stateProto,
                                                         { batch.size, self.args.rnnSize })
	end
	
	local states = onmt.utils.Tensor.copyTensorTable(self.statesProto, encoderStates)
	
	local prevOutputs = {}
	
	local realMaxLength = maxLength
	
	-- Start sampling
	for t = 1, maxLength do
		local input
		
		if t == 1 then
			input = sampledSeq[t]
		else
			input = sampledSeq[t - 1]
		end
		
		prevOutputs, states = self:forwardOne(input, states, context, prevOutputs, t)
		
		local pred = prevOutputs[3][1]
		
		pred:exp() -- exp to get the distribution
		
		-- get the argmax ( we are using greedy sampling )
		local _, indx = pred:max(2)
		
		sampledSeq[t]:copy(indx:resize(batch.size))
			
		local continueFlag = false 
		for b = 1, batch.size do
			if input[b] == onmt.Constants.EOS or input[b] == onmt.Constants.PAD then -- stop sampling if input is EOS or PAD
				sampledSeq[t][b] = onmt.Constants.PAD
			else
				continueFlag = true -- one of the sentences is not finished yet
			end
		end
	
		if continueFlag == false then
			realMaxLength = t -- Avoid wasting time in sampling too many PAD
			break
		end
	end
	
	sampledSeq = sampledSeq:narrow(1, 1, realMaxLength)  
	return sampledSeq
end


-- Two functions to control sampling (to make training faster when sampling is not necessary)
function Decoder:enableSampling(t)
	
	self.network.decoderSampler:enable()
	if t then
		self:net(t).decoderSampler:enable()
	else
		for i = 1, #self.networkClones do
			self.networkClones[i].decoderSampler:enable()
		end
	end
end

function Decoder:disableSampling()
	self.network.decoderSampler:disable()
	
	for i = 1, #self.networkClones do
		self.networkClones[i].decoderSampler:disable()
	end
end


function Decoder:setNSamplingSteps(nstep)
	--~ self.args.nstepsinit = nstep
	self.args.nSamplingSteps = nstep
end
