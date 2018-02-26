classdef Compensation < handle
	% Compilation of compensation methods from the Weiss Lab flow cytometry MATLAB repository
	%
	%	Methods are implemented as static functions, so they can be called directly
	%	or after creating a handle to this class.
	%
	%		Ex:
	%		data = Compensation.openFiles(TF_marker, args);
	%
	%		Ex2:
	%		comp = Compensation();
	%		compData = comp.compensateMatrix(inputData, coefficients);
	%
    %   Functions:
    %
    %       [xBleed, yComp] = compensateSC(JCFile, singleColorFile, correctFile, bC, cC, plotsOn)
    %       compData		= compensateBatchSC(jcData, scData, scChannels, inputData, fixChannels, dataType, gate, plotsOn)
    %		[data, wtData, scData, fitParams] = compensateMatrixBatch(data, channels, wtData, scData, dataType, gate, plotsOn)
	%       compdData		= compensateMatrix(inputData, coefficients)
    %       YI				= lsq_lut_piecewise(x, y, XI)
    %
    % Written/Compiled by
	% Ross Jones
	% jonesr18@mit.edu
    % Weiss Lab, MIT
	
	methods (Static)		
		
		function [coeffs, ints, figFits] = computeCoeffs(scData, channels, options)
			% Finds the coefficients for linear fits between each channel
			% when observing bleed-through.
			%
			%	[coeffs, ints, figFits] = computeCoeffs(dataMatrix, channels, plotsOn, minFunc)
			%
			%	Inputs
			%
			%		scData		<cell> A cell list of C NxC data matrices containing 
			%					N cell fluroescenct values in C channels from C 
			%					single-color controls. The ordering of the columns 
			%					(channels) should match the ordering of the 
			%					corresponding controls in the cell list. 
			%
			%		channels	<cell> A cell list of C channel names
			%					corresponding with the cell list and
			%					matrix data in scData.
			%
			%		options		<struct> (optional) Optional property-value pairs:
			%			'minFunc':		A user-defined function for residual
			%							minimzation during fitting. 
			%								Default = @(x) sum(x.^2)
			%								(least-squares approximation)
			%			'plotsOn':		If TRUE, shows the compensation
			%							plots, which are passed back to
			%							the caller (otherwise returns empty).
			%			'plotLin':		If TRUE (and plotsOn = TRUE), then the
			%							fits are plotted in linear space, rather
			%							than biexponential.
			%			'doMEF':		If TRUE, does logicle conversion with
			%							MEF-unit scaling
			%			'params':		<params> enables setting the logical
			%							function parameters
			%								(see Transforms.lin2logicle())
			%
			%	Outputs
			%
			%		coeffs		<numeric> A CxC matrix of linear coefficients
			%					representing the bleed-through between channels
			%
			%		ints		<numeric> A Cx1 vector of linear intercepts
			%					representing autofluorescence in each channel
			%
			%		figFits		<struct> If options.plotsOn = TRUE, this returns 
			%					a handle to the generated figure with overlaid
			%					fit lines on the fitted data. If options.plotsOn
			%					is not passed or is FALSE, this returns empty.
			%
			%	Implementation notes
			%
			%		The function simultaneously fits coeffs and ints to all the
			%		data from each control and channel. ints is fixed for each
			%		channel, so some fits will appear off before compensation is
			%		applied, after which they are corrected. 
			%
			%		We also discard any value in a bleed channel that is > 10x
			%		the average value, as these often are spillover between
			%		tubes during data collection and can mess up compensation. 
			%
			% Written By
			% Ross Jones
			% jonesr18@mit.edu
			% Weiss Lab, MIT
			%
			% Update log:
			% 
			
			% Check inputs
			zCheckInputs_computeCoeffs();
			
			% Exclude outliers by ignoring any point that is >10x greater 
			% on the fix axis as the bleed axis. 
			for chB = 1:numel(channels)
				nonChB = setdiff(1:numel(channels), chB);
				outliers = any(scData{chB}(:, nonChB) > (10 * abs(scData{chB}(:, chB))), 2);
				scData{chB} = scData{chB}(~outliers, :);
			end
			
			% Equalize the number of points between each control
			numPoints = min(cellfun(@(x) size(x, 1), scData));
			scData = cellfun(@(x) x(FlowAnalysis.subSample(size(x, 1), numPoints), :), ...
				scData, 'uniformoutput', false);
			
			% Fitting initial conditions
			A0 = 10 * ones(numel(channels), 1);					% Intercepts (Autofluorescence)
			K0 = zeros(numel(channels)^2 - numel(channels), 1);	% Coefficients (Bleed-through)
			
			% Iterate over each pair of channels and compute fits
			optimOptions = optimset('Display', 'off');
			[minResult, fval] = fminsearch(@(x) fitFunc(x, options.minFunc), [A0; K0], optimOptions);
			fprintf('Linear fits obtained with obj func val %.2f\n', fval);
			ints = minResult(1:numel(channels));
			coeffs = eye(numel(channels));
			coeffs(~logical(eye(numel(channels)))) = minResult(numel(channels) + 1 : end);
			
			% Set up figure to view fitting (if applicable)
			if ~all(logical(options.plotsOn))
				figFits = [];
				return % No need to process the rest of the code
			end
			
			% Prep figure
			figFits = figure();
			spIdx = 0;
			xrange = logspace(0, log10(max(cellfun(@(x) max(x(:)), scData))), 100);
			if ~all(logical(options.plotLin))
				xrange = Transforms.lin2logicle(xrange, options.doMEF, options.logicle);
			end
			
			for chF = 1:numel(channels)
				for chB = 1:numel(channels) 
					
					fitVals = xrange * coeffs(chF, chB) + ints(chF);
					
					spIdx = spIdx + 1;
					ax = subplot(numel(channels), numel(channels), spIdx);
					hold(ax, 'on')
					
					if all(logical(options.plotLin))
						xdata = scData{chB}(:, chB);
						ydata = scData{chB}(:, chF);
					else
						% Do conversions
						xdata = Transforms.lin2logicle(scData{chB}(:, chB), ...
								options.doMEF, options.logicle);
						ydata = transforms.lin2logicle(scData{chB}(:, chF), ...
								options.doMEF, options.logicle);
						fitVals = Transforms.lin2logicle(fitVals, ...
								options.doMEF, options.logicle);
						
						% Convert axes
						Plotting.biexpAxes(ax, true, true, false, ...
								 options.doMEF, options.logicle);
					end
					
					plot(ax, xdata, ydata, '.', 'MarkerSize', 4)
					plot(ax, xrange, fitVals, '-', 'linewidth', 4)
					
					% Axis labeling
					title(sprintf('Slope: %.4f | Intercept: %.2f', ...
						coeffs(chF, chB), ints(chF)), 'fontsize', 14)
					if (chF == numel(channels))
						xlabel(strrep(channels{chB}, '_', '-'))
					end
					if (chB == 1)
						ylabel(strrep(channels{chF}, '_', '-'))
					end
				end
			end
			
			
			% --- Helper Functions --- %
			
			
			function zCheckInputs_computeCoeffs()
				
				validateattributes(scData, {'cell'}, {}, mfilename, 'scData', 1);
				for sc = 1:numel(scData) 
					validateattributes(scData{sc}, {'numeric'}, {}, mfilename, sprintf('scData{%d}', sc), 1);
				end
				validateattributes(channels, {'cell'}, {}, mfilename, 'channels', 2);
				assert(numel(channels) == numel(scData), 'Incorrect number of channel controls or labels!')
				assert(numel(channels) == size(scData{1}, 2), 'Incorrect number of channel data or labels!');
				assert(numel(channels) > 1, 'Compensation with just one channel is useless!');
				
				if ~exist('options', 'var'), options = struct(); end
				if ~isfield(options, 'plotsOn'), options.plotsOn = false; end
				if ~isfield(options, 'plotLin'), options.plotLin = false; end
				if isfield(options, 'minFunc')
					validateattributes(options.minFunc, {'function_handle'}, {}, mfilename, 'options.minFunc', 4)
				else
					options.minFunc = @(x) sum(x.^2);
				end
				if ~isfield(options, 'logicle'), options.logicle = struct(); end
				if ~isfield(options, 'doMEF'), options.doMEF = false; end
			end
			
			
			function out = fitFunc(p, minFunc)
				% Fit function for computing linear fits between bleed 
				% and fix channels in each scData control
				
				% Think about trying to fit everything at once?
				
				% Setup fit matrix
				A = p(1:numel(channels));
				K = eye(numel(channels));
				K(~logical(eye(numel(channels)))) = p(numel(channels) + 1 : end);
				
				% Find regression with each channel
				residuals = zeros(1, numel(channels));
				for ch = 1:numel(channels)
					fixedData = K \ (scData{ch}' - A);
					chans = setdiff(1:numel(channels), ch); % Skip ch since is not min to 0
					residuals(ch) = minFunc(reshape(fixedData(chans, :), 1, []));
				end
				
				out = sum(residuals);
			end
		end
		
		
        function compData = matrixComp(uncompData, coeffs)
            % Compensates data using linear coefficients for bleed-through between channels.
            % 
            %   compData = matrixComp(uncompData, coeffs)
            %   
            %   Inputs: 
            %       uncompData		A CxN matrix of data points corresponding with
			%						N cells in C channels to be compensated. 
            %
            %       coeffs			A CxC matrix of coefficients corresponding with
            %						the slope of lines of best fit between C channels 
            %						bleeding into each other. 
            %
            %       Outputs:
            %           compData	An NxM matrix with compensated data.
            %   
            %   This method solves the linear set of equations:
            %       X_observed = A * X_real
            %
            %   'uncompData' corresponds with 'X_observed' and 'coeffs'
            %   corresponds with the matrix 'A'. We invert 'A' to solve
            %   for X_real, which is returned as 'compdData'.
            %
			% Written By
            % Ross Jones
			% jonesr18@mit.edu
            % Weiss Lab
            % 2017-06-06
            %
            % Update Log:
            %
            % ...
            
            % Check inputs are valid
            zCheckInputs_compensateMatrix();
            
            % Compensate data
            compData = coeffs \ uncompData;
            
            
            % --- Helper functions --- %
            
            
            function zCheckInputs_compensateMatrix()
                
                % Check types
                validateattributes(uncompData, {'numeric'}, {}, mfilename, 'uncompData', 1);
                validateattributes(coeffs, {'numeric'}, {}, mfilename, 'coeffs', 2);
                
                % Check sizes
                assert(size(uncompData, 1) == size(coeffs, 2), ...
                    '# Channels in ''uncompData'' (%d) and ''coeffs'' (%d) are not the same!', ...
                    size(uncompData, 1), size(coeffs, 2))
                assert(size(coeffs, 1) == size(coeffs, 2), ...
                    '''coeffs'' is not square! (H = %d, W = %d)', ...
                    size(coeffs, 1), size(coeffs, 2))
            end
        end
		
		
		function YI = lsq_lut_piecewise(x, y, XI)
			% LSQ_LUT_PIECEWISE Piecewise linear interpolation for 1-D interpolation (table lookup)
			%   YI = lsq_lut_piecewise( x, y, XI ) obtain optimal (least-square sense)
			%   vector to be used with linear interpolation routine.
			%   The target is finding Y given X the minimization of function 
			%           f = |y-interp1(XI,YI,x)|^2
			%   
			%   INPUT
			%       x measured data vector
			%       y measured data vector
			%       XI break points of 1-D table
			%
			%   OUTPUT
			%       YI interpolation points of 1-D table
			%           y = interp1(XI,YI,x)
			%
			% Written By
			% Jeremy Gam
			% jgam@mit.edu
			% Weiss Lab, MIT
			% 
			% Update Log:
			% 
            
            % Turn off this warning, which results from using very negative values in XI
            warning('off', 'MATLAB:rankDeficientMatrix')
            
            % Check vector sizes
			if size(x, 2) ~= 1
				error('Vector x must have dimension n x 1.');   
			elseif size(y, 2) ~= 1
				error('Vector y must have dimension n x 1.');    
			elseif size(x, 1) ~= size(y, 1)
				error('Vector x and y must have dimension n x 1.'); 
			end

			% matrix defined by x measurements
			A = sparse([]); 

			% vector for y measurements
			Y = []; 

			for j = 2:length(XI)
				
				% get index of points in bin [XI(j-1) XI(j)]
				ix = (x >= XI(j - 1) & x < XI(j) );
				
				% check if we have data points in bin
                % doesn't matter
% 				if ~any(ix)
% 					warning('Bin [%f %f] has no data points, check estimation. Please re-define X vector accordingly.',XI(j-1),XI(j));
% 				end
				
				% get x and y data subset
				x_ = x(ix);
				y_ = y(ix);
				
				% create temporary matrix to be added to A
				tmp = [(1 - (x_ - XI(j - 1)) / (XI(j) - XI(j - 1))),...
                       (    (x_ - XI(j - 1)) / (XI(j) - XI(j - 1))) ];
				
				% build matrix of measurement with constraints
				[m1, n1] = size(A);
				[m2, n2] = size(tmp);
				A = [A, zeros(m1, n2 - 1); 
                     zeros(m2, n1 - 1), tmp]; %#ok<AGROW>
				
				% concatenate y measurements of bin
				Y = [Y; y_]; %#ok<AGROW>
			end

			% obtain least-squares Y estimation
			YI = (A \ Y)';

		end
		
	end
	
end