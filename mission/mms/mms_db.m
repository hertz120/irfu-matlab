classdef mms_db < handle
  %MMS_DB Summary of this class goes here
  %   Detailed explanation goes here
  
  properties
    databases
    cacheEnabled = false
    cacheTimeout = 600;  % db cache timeout in sec
    cacheSizeMax = 1024; % db cache max size in mb
  end
  
  properties (Access = private)
    cache
  end
  
  methods
    function obj=mms_db()
      obj.databases = [];
    end
    function obj = add_db(obj,dbInp)
      if ~isa(dbInp,'mms_file_db')
        error('expecting MMS_FILE_DB input')
      end
      if any(arrayfun(@(x) strcmpi(x.id,dbInp.id), obj.databases))
        irf.log('warning',['Database [' dbInp.id '] already added'])
        return
      end
      obj.databases = [obj.databases dbInp];
    end
    
    function dobjLoaded = get_from_cache(obj,fileName)
      dobjLoaded = [];
      if ~obj.cacheEnabled || isempty(obj.cache), return, end
      idx = cellfun(@(x) strcmp(fileName,x),obj.cache.names);
      if ~any(idx), return, end
      if now() > obj.cache.loaded(idx) + obj.cacheTimeout/86400
        obj.purge_cache(), return
      end
      dobjLoaded = obj.cache.dobj{idx};
    end
    
    function add_to_cache(obj,fileName,dobjLoaded)
      if ~obj.cacheEnabled, return, end
      if ~isempty(obj.cache)
        obj.purge_cache();
        idx = cellfun(@(x) strcmp(fileName,x),obj.cache.names);
        if any(idx), return, end % file is already there
      end
      if isempty(obj.cache)
        obj.cache.loaded = now();
        obj.cache.names = {fileName};
        obj.cache.dobj = {dobjLoaded};
        return
      end
      obj.cache.loaded = [obj.cache.loaded now()];
      obj.cache.names = [obj.cache.names {fileName}];
      obj.cache.dobj = [obj.cache.dobj {dobjLoaded}];
      % check if we did not exceed cacheSizeMax
      cacheTmp = obj.cache; w = whos('cacheTmp'); t0 = now(); %#ok<NASGU>
      while w.bytes > obj.cacheSizeMax*1024*1024
        if length(obj.cache.loaded) == 1, break, end
        dt = t0 - obj.cache.loaded; idx = dt == max(dt);
        disp(['purging ' obj.cache.names{idx}])
        obj.cache.loaded(idx) = [];
        obj.cache.names(idx) = [];
        obj.cache.dobj(idx) = [];
        cacheTmp = obj.cache; %#ok<NASGU>
        w = whos('cacheTmp');
      end
    end
    
    function display_cache(obj)
      % Display cache memory usage and contents
      if ~obj.cacheEnabled, disp('DB caching disabled'), return, end
      if isempty(obj.cache), disp('DB cache empty'), return, end
      cacheTmp = obj.cache; w = whos('cacheTmp'); t0 = now(); %#ok<NASGU>
      fprintf('DB cache using %.1f MB\n',w.bytes/1024/1024)
      dt = t0 - obj.cache.loaded;
      [dt,idx] = sort(dt);
      for i=1:length(idx)
        fprintf('%s (expires in %d sec)\n', obj.cache.names{idx(i)},...
          ceil(obj.cacheTimeout - dt(i)*86400))
      end
    end
    
    function purge_cache(obj)
      if ~obj.cacheEnabled, return, end
      if ~isempty(obj.cache) % purge old entries from cache
        t0 = now;
        idx = t0 > obj.cache.loaded + obj.cacheTimeout/86400;
        obj.cache.loaded(idx) = [];
        obj.cache.names(idx) = [];
        obj.cache.dobj(idx) = [];
      end
    end
    
   function fileList = list_files(obj,filePrefix,tint)
     fileList =[];
     if isempty(obj.databases)
       irf.log('warning','No databases initialized'), return
     end
     for iDb = 1:length(obj.databases)
       fileList = [fileList obj.databases(iDb).list_files(filePrefix,tint)]; %#ok<AGROW>
     end
   end
   
   function res = get_variable(obj,filePrefix,varName,tint)
     narginchk(4,4)
     res = [];
     
     fileList = list_files(obj,filePrefix,tint);
     if isempty(fileList), return, end
     
     loadedFiles = obj.load_list(fileList,varName);
     if numel(loadedFiles)==0, return, end
     
     flagDataobj = isa(loadedFiles{1},'dataobj');
     for iFile = 1:length(loadedFiles)
       if flagDataobj, append_sci_var(loadedFiles{iFile})
       else append_ancillary_var(loadedFiles{iFile});
       end
     end
     
     function append_ancillary_var(ancData)
       if isempty(ancData), return, end
       if ~isstruct(ancData) || ~(isfield(ancData,varName) ...
           && isfield(ancData,'time'))
         error('Data does not contain %s or time',varName)
       end
       time = ancData.time; data = ancData.(varName);
       if isempty(res), res = struct('time',time,varName,data); return, end
       res.time = [res.time; time];
       res.(varName) = [res.(varName); data];
       % check for overlapping time records and remove duplicates
       [~, idxSort] = sort(res.time);
       [res.time, idxUniq] = unique(res.time(idxSort));
       irf.log('warning',...
          sprintf('Discarded %d data points',length(idxSort)-length(idxUniq)))
       res.(varName) = res.(varName)(idxSort(idxUniq),:);
     end
     
     function append_sci_var(sciData)
       if isempty(sciData), return, end
       if ~isa(sciData,'dataobj')
         error('Expecting DATAOBJ input')
       end
       v = get_variable(sciData,varName);
       if isempty(v)
         irf.log('waring','Empty return from get_variable()')
         return
       end
       if ~isstruct(v) || ~(isfield(v,'data') && isfield(v,'DEPEND_0'))
         error('Data does not contain DEPEND_0 or DATA')
       end
       
       if isempty(res), res = v; return, end
       if iscell(res), res = [res {v}]; return, end
       if ~comp_struct(res,v), res = [{res}, {v}]; return, end
       
       res.DEPEND_0.data = [res.DEPEND_0.data; v.DEPEND_0.data];
       res.data = [res.data; v.data];
       % check for overlapping time records
       [~,idxUnique] = unique(res.DEPEND_0.data); 
       idxDuplicate = setdiff(1:length(res.DEPEND_0.data), idxUnique);
       res.DEPEND_0.data(idxDuplicate) = [];
       switch ndims(res.data)
         case 2, res.data(idxDuplicate, :) = [];
         case 3, res.data(idxDuplicate, :, :) = [];
         case 4, res.data(idxDuplicate, :, :, :) = [];
         case 5, res.data(idxDuplicate, :, :, :, :) = [];
         case 6, res.data(idxDuplicate, :, :, :, :, :) = [];
       end
       res.nrec = length(res.DEPEND_0.data); res.DEPEND_0.nrec = res.nrec;
       nDuplicate = length(idxDuplicate);
       if nDuplicate
         irf.log('warning',sprintf('Discarded %d data points',nDuplicate))
       end
       [res.DEPEND_0.data,idxSort] = sort(res.DEPEND_0.data);
       nd = ndims(res.data);
       switch nd
         case 2, res.data = res.data(idxSort, :);
         case 3, res.data = res.data(idxSort, :, :);
         case 4, res.data = res.data(idxSort, :, :, :);
         case 5, res.data = res.data(idxSort, :, :, :, :);
         case 6, res.data = res.data(idxSort, :, :, :, :, :);
         otherwise
           errStr = 'Cannot handle more than 6 dimensions.';
           irf.log('critical', errStr);
           error(errStr);
       end
       function res = comp_struct(s1,s2)
       % Compare structures
         narginchk(2,2), res = false;
         
         if ~isstruct(s1) ||  ~isstruct(s2), error('expecting STRUCT input'), end
         if isempty(s1) && isempty(s2), res = true; return
         elseif xor(isempty(s1),isempty(s2)), return
         end
         
         fields1 = fields(s1); fields2 = fields(s2);
         if ~comp_cell(fields1,fields2), return, end
         
         for iField=1:length(fields1)
           f = fields1{iField};
           % data, nrec and the GlobalAttributes Generation_date,
           % Logical_file_id and Data_version will almost always differ
           % between files.
           ignoreFields = {'data','nrec','Generation_date',...
             'Logical_file_id','Data_version','Parents'};
           if ~isempty(intersect(f,ignoreFields)), continue, end
           if isnumeric(s1.(f)) || ischar(s1.(f))
             if ~all(all(all(s1.(f)==s2.(f)))), return, end
           elseif isstruct(s1.(f)), if ~comp_struct(s1.(f),s2.(f)), return, end
           elseif iscell(s1.(f)), if ~comp_cell(s1.(f),s2.(f)), return, end
           else
             error('cannot compare : %s',f)
           end
         end
         res = true;
       end % COMP_STRUCT
       function res = comp_cell(c1,c2)
         %Compare cells
         narginchk(2,2), res = false;
         
         if ~iscell(c1) ||  ~iscell(c2), error('expecting CELL input'), end
         if isempty(c1) && isempty(c2), res = true; return
         elseif xor(isempty(c1),isempty(c2)), return
         end
         if ~all(size(c1)==size(c2)), return, end
         
         [n,m] = size(c1);
         for iN = 1:n,
           for iM = 1:m
             if ischar(c1{iN, iM}) && ischar(c2{iN,iM})
               if ~strcmp(c1{iN, iM},c2{iN,iM}), return , end
             elseif iscell(c1{iN, iM}) && iscell(c2{iN,iM})
               if ~comp_cell(c1{iN, iM},c2{iN,iM}), return , end
             else
               irf.log('warining','can only compare chars')
               res = true; return
             end
             
           end
         end
         res = true;
       end % COMP_CELL
     end % APPEND_SCI_VAR
   end % GET_VARIABLE
   
   function res = load_list(obj,fileList,mustHaveVar)
     narginchk(2,3), res = {};
     if isempty(fileList), return, end
     if nargin==2, mustHaveVar = ''; end
     
     for iFile=1:length(fileList)
       fileToLoad = fileList(iFile);
       dobjLoaded = obj.get_from_cache(fileToLoad.name);
       if isempty(dobjLoaded)
         db = obj.get_db(fileToLoad.dbId);
         if isempty(db) || ~db.file_has_var(fileToLoad.name,mustHaveVar)
           continue
         end
         dobjLoaded = db.load_file(fileToLoad.name);
         obj.add_to_cache(fileToLoad.name,dobjLoaded)
       end
       res = [res {dobjLoaded}]; %#ok<AGROW>
     end
   end
   
   function res = get_db(obj,id)
     idx = arrayfun(@(x) strcmp(x.id,id),obj.databases);
     res = obj.databases(idx);
   end
   
   function res = get_ts(obj,filePrefix,varName,tint)
     narginchk(4,4)
     res = [];
     v = get_variable(obj,filePrefix,varName,tint);
     if isempty(v), return, end
     if numel(v)==1
       res = mms.variable2ts(v);
       res = res.tlim(tint);
     else
       res = cell(1,numel(v));
       for iV = 1:numel(v)
         resTmp = mms.variable2ts(v{iV});
         res{iV} = resTmp.tlim(tint);
       end
     end
   end
  end
end
