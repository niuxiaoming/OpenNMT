--[[ Data management and batch creation. Handles data created by `preprocess.lua`. ]]
local Dataset = torch.class("Dataset")

--[[ Initialize a data object given aligned tables of IntTensors `srcData`
  and `tgtData`.
--]]
function Dataset:__init(srcData, tgtData)

  self.src = srcData.words
  self.srcFeatures = srcData.features

  if tgtData ~= nil then
    self.tgt = tgtData.words
    self.tgtFeatures = tgtData.features
  end
end

--[[ Setup up the training data to respect `maxBatchSize`. ]]
function Dataset:setBatchSize(maxBatchSize, groupTargetLength)

  self.batchRange = {}
  self.maxSourceLength = 0
  self.maxTargetLength = 0
  self.groupTargetLength = groupTargetLength or false
  
  -- sanity check
  assert(self.groupTargetLength == false or self.tgt, 'Target data must be defined to group')

  -- Prepares batches in terms of range within self.src and self.tgt.
  local offset = 0
  local batchSize = 1
  local sourceLength = 0
  local targetLength = 0
  
  
  if self.groupTargetLength == false then

	  for i = 1, #self.src do
			-- Set up the offsets to make same source size batches of the
			-- correct size.
			if batchSize == maxBatchSize or self.src[i]:size(1) ~= sourceLength then
				if i > 1 then
					table.insert(self.batchRange, { ["begin"] = offset, ["end"] = i - 1 })
				end

				offset = i
				batchSize = 1
				sourceLength = self.src[i]:size(1)
				targetLength = 0
			else
				batchSize = batchSize + 1
			end

			self.maxSourceLength = math.max(self.maxSourceLength, self.src[i]:size(1))

			if self.tgt ~= nil then
				-- Target contains <s> and </s>.
				local targetSeqLength = self.tgt[i]:size(1) - 1
				targetLength = math.max(targetLength, targetSeqLength)
				self.maxTargetLength = math.max(self.maxTargetLength, targetSeqLength)
			end
	  end
  
  else -- group sentences by target sizes
		
		for i = 1, #self.tgt do
		
			local currentTargetLength = self.tgt[i]:size(1) - 1 -- target contain <s> and </s>
			--~ print(currentTargetLength)
			
			if batchSize == maxBatchSize or currentTargetLength ~= targetLength then
				if i > 1 then
					table.insert(self.batchRange, { ["begin"] = offset, ["end"] = i - 1 })
				end
				
				offset = i 
				batchSize = 1
				targetLength = currentTargetLength
				sourceLength = 0
			else
				batchSize = batchSize + 1
			end
			
			self.maxTargetLength = math.max(self.maxTargetLength, currentTargetLength)
			
			-- for source side
			local currentSourceLength = self.src[i]:size(1)
			sourceLength = math.max(sourceLength, currentSourceLength)
			self.maxSourceLength = math.max(self.maxSourceLength, currentSourceLength)
		end
  end
  -- Catch last batch.
  table.insert(self.batchRange, { ["begin"] = offset, ["end"] = #self.src })
end

--[[ Return number of batches. ]]
function Dataset:batchCount()
  if self.batchRange == nil then
    if #self.src > 0 then
      return 1
    else
      return 0
    end
  end
  return #self.batchRange
end

--[[ Get `Batch` number `idx`. If nil make a batch of all the data. ]]
function Dataset:getBatch(idx)
  if #self.src == 0 then
    return nil
  end

  if idx == nil or self.batchRange == nil then
    return onmt.data.Batch.new(self.src, self.srcFeatures, self.tgt, self.tgtFeatures)
  end

  local rangeStart = self.batchRange[idx]["begin"]
  local rangeEnd = self.batchRange[idx]["end"]

  local src = {}
  local tgt

  if self.tgt ~= nil then
    tgt = {}
  end

  local srcFeatures = {}
  local tgtFeatures = {}

  for i = rangeStart, rangeEnd do
    table.insert(src, self.src[i])

    if self.srcFeatures[i] then
      table.insert(srcFeatures, self.srcFeatures[i])
    end

    if self.tgt ~= nil then
      table.insert(tgt, self.tgt[i])

      if self.tgtFeatures[i] then
        table.insert(tgtFeatures, self.tgtFeatures[i])
      end
    end
  end

  return onmt.data.Batch.new(src, srcFeatures, tgt, tgtFeatures)
end

return Dataset
