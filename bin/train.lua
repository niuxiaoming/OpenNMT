require('onmt.init')

local cmd = onmt.utils.ExtendedCmdLine.new('train.lua')

-- First argument define the model type: seq2seq/lm - default is seq2seq.
local modelType = cmd.getArgument(arg, '-model_type') or 'seq2seq'

local modelClass = onmt.ModelSelector(modelType)

-- Options declaration.
local options = {
  {'-data',       '', [[Path to the training *-train.t7 file from preprocess.lua]],
                      {valid=onmt.utils.ExtendedCmdLine.nonEmpty}},
  {'-save_model', '', [[Model filename (the model will be saved as
                            <save_model>_epochN_PPL.t7 where PPL is the validation perplexity]],
                      {valid=onmt.utils.ExtendedCmdLine.nonEmpty}}
}

cmd:setCmdLineOptions(options, 'Data')

onmt.Model.declareOpts(cmd)
modelClass.declareOpts(cmd)
onmt.train.Optim.declareOpts(cmd)
onmt.train.Trainer.declareOpts(cmd)
onmt.train.Checkpoint.declareOpts(cmd)

cmd:text('')
cmd:text('**Other options**')
cmd:text('')

onmt.utils.Cuda.declareOpts(cmd)
onmt.utils.Memory.declareOpts(cmd)
onmt.utils.Logger.declareOpts(cmd)
onmt.utils.Profiler.declareOpts(cmd)

cmd:option('-seed', 3435, [[Seed for random initialization]], {valid=onmt.utils.ExtendedCmdLine.isUInt()})

local opt = cmd:parse(arg)

local function main()

  torch.manualSeed(opt.seed)

  _G.logger = onmt.utils.Logger.new(opt.log_file, opt.disable_logs, opt.log_level)
  _G.profiler = onmt.utils.Profiler.new(false)

  onmt.utils.Cuda.init(opt)
  onmt.utils.Parallel.init(opt)

  local checkpoint
  checkpoint, opt = onmt.train.Checkpoint.loadFromCheckpoint(opt)

  _G.logger:info('Training '..modelClass.modelName()..' model')

  -- Create the data loader class.
  _G.logger:info('Loading data from \'' .. opt.data .. '\'...')

  local dataset = torch.load(opt.data, 'binary', false)

  -- Keep backward compatibility.
  dataset.dataType = dataset.dataType or 'bitext'

  -- Check if data type matches the model.
  if dataset.dataType ~= modelClass.dataType() then
    _G.logger:error('Data type: \'' .. dataset.dataType .. '\' does not match model type: \'' .. modelClass.dataType() .. '\'')
    os.exit(0)
  end

  local trainData = onmt.data.Dataset.new(dataset.train.src, dataset.train.tgt)
  local validData = onmt.data.Dataset.new(dataset.valid.src, dataset.valid.tgt)

	-- sortTarget means batches will group samples with the same target size
	--~ print(dataset.sortTarget)
  trainData:setBatchSize(opt.max_batch_size, dataset.sortTarget) 
  validData:setBatchSize(opt.max_batch_size, dataset.sortTarget)

  if dataset.dataType == 'bitext' then
    _G.logger:info(' * vocabulary size: source = %d; target = %d',
                   dataset.dicts.src.words:size(), dataset.dicts.tgt.words:size())
    _G.logger:info(' * additional features: source = %d; target = %d',
                   #dataset.dicts.src.features, #dataset.dicts.tgt.features)
  else
    _G.logger:info(' * vocabulary size: %d', dataset.dicts.src.words:size())
    _G.logger:info(' * additional features: %d', #dataset.dicts.src.features)
  end
  _G.logger:info(' * maximum sequence length: source = %d; target = %d',
                 trainData.maxSourceLength, trainData.maxTargetLength)
  _G.logger:info(' * number of training sentences: %d', #trainData.src)
  _G.logger:info(' * maximum batch size: %d', opt.max_batch_size)

  _G.logger:info('Building model...')
  
  onmt.Constants.MAX_TARGET_LENGTH = trainData.maxTargetLength

  local model
  
  local _modelClass = onmt.ModelSelector(modelType)
  if checkpoint.models then
	_G.model = _modelClass.load(opt, checkpoint.models, dataset.dicts)
  else
    local verbose = true
    _G.model = _modelClass.new(opt, dataset.dicts, verbose)
  end
  onmt.utils.Cuda.convert(_G.model)
  
  model = _G.model
  
  model.sortTarget = dataset.sortTarget
  
  if model.sortTarget then
		_G.logger:info(' * Data is sorted by target sentences ')
  end
  
  
  -- Define optimization method.
  local optimStates = (checkpoint.info and checkpoint.info.optimStates) or nil
  local optim = onmt.train.Optim.new(opt, optimStates)

  -- Initialize trainer.
  local trainer = onmt.train.Trainer.new(opt)

  -- Launch training.
  trainer:train(model, optim, trainData, validData, dataset, checkpoint.info)

  _G.logger:shutDown()
end

main()
