require('onmt.init')

local cmd = onmt.utils.ExtendedCmdLine.new('rank_score.lua')

local options = {
  {'-src', '', [[Source sequence to decode (one line per sequence)]]},
  {'-input', '', [[Nbest list for the target side]], {valid=onmt.utils.ExtendedCmdLine.nonEmpty}},
  {'-output', 'pred.txt', [[Path to output the new n_best list]]},
  {'-neg_weight', '1', [[Weight for negative scores]]},
  {'-pos_weight', '1', [[Weight for positive scores]]},
  {'-sub_weight', '0.5', [[Weight for scores after the first (original from n-best creator)]]}
}

cmd:setCmdLineOptions(options, 'Data')

cmd:text('')
cmd:text('**Other options**')
cmd:text('')

--~ onmt.utils.Cuda.declareOpts(cmd)
onmt.utils.Logger.declareOpts(cmd)

local function reportScore(name, scoreTotal, wordsTotal)
  _G.logger:info(name .. " AVG SCORE: %.2f, " .. name .. " PPL: %.2f",
                 scoreTotal / wordsTotal,
                 math.exp(-scoreTotal/wordsTotal))
end

local function main()
  local opt = cmd:parse(arg)

  _G.logger = onmt.utils.Logger.new(opt.log_file, opt.disable_logs, opt.log_level)

  --~ local srcReader = onmt.utils.FileReader.new(opt.src)
  --~ local srcBatch = {}
  
  local hypReader = onmt.utils.FileReader.new(opt.input)
  

  local outFile = io.open(opt.output, 'w')
  local sentId = 0
  local batchId = 1

  local predScoreTotal = 0
  local predWordsTotal = 0
	
	
	local hypID = -1
	local srcSent
	local tgtNBest = {}
	local scores = {}	

	
	local function processBatch()
		local listSize = #tgtNBest
		local score = torch.DoubleTensor(listSize):zero()
		
		-- Accumulate the score: using sum
		for n = 1, listSize do
			for m = 1, #tgtScores[1] do
				
				-- Nematus score is negative
				if tgtScores[n][m] > 0 then
					tgtScores[n][m] = - tgtScores[n][m] * opt.pos_weight
				else
					tgtScores[n][m] = tgtScores[n][m] * opt.neg_weight
				end
				
				if m > 1 then
					tgtScores[n][m] = tgtScores[n][m] * opt.sub_weight
				end
				
				score[n] = score[n] + tgtScores[n][m]
			end 
			
			local length = #tgtNBest[n]
		end
	
	
		-- sort (descending)
		local sorted_score, sorted_id = torch.sort(score, 1, true) 
		
		local bestScore = score[sorted_id[1]]
		local bestID = sorted_id[1]
		local bestSentence = tgtNBest[bestID]
		
		local sentWithScore = string.format("%s : %.9f", bestSentence, bestScore)
		_G.logger:info("BEST HYP: ")
		_G.logger:info(sentWithScore)
		outFile:write(bestSentence .. "\n")
	
	end
	
	while true do
		
		local currentTgtTokens = hypReader:next()
		
		-- end of file
    if currentTgtTokens == nil then
			-- proceed this batch and print out result			
			processBatch()
			break
		end
		
		local length = #currentTgtTokens
		
		if length > 0 then
			-- find the position of the last "|||"
			local lastMarker
			for j = length, 1, -1 do
				if currentTgtTokens[j] == '|||' then
					lastMarker = j
					break
				end
			end
			
			-- build sentence
			local sentTokens = {}
			for j = 3, lastMarker -1 do
				table.insert(sentTokens, currentTgtTokens[j])
			end
			
			
			local scores = {}
			for j = lastMarker + 1, length do
				table.insert(scores, tonumber(currentTgtTokens[j]))
			end
			
			local tgtHyp = table.concat(sentTokens, ' ')
			
			local currentHypId = tonumber(currentTgtTokens[1])
			
			-- end of last sentence -> proceed this batch
			if currentHypId > hypID then
				
				if hypID > -1 then
					processBatch()
				end
				
				-- build next batch
				tgtNBest = {tgtHyp}
				tgtTokens = {currentTgtTokens}				
				if hypID == -1 then 
					hypID = currentHypId
				else
					hypID = hypID + 1
				end
				tgtScores = {scores}
			else
				table.insert(tgtNBest, tgtHyp)
				table.insert(tgtScores, scores)
				table.insert(tgtTokens, currentTgtTokens)
			end
		
		end

		end
  
  outFile:close()
  _G.logger:shutDown()
end

main()
