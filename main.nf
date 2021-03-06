#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/diaproteomics
========================================================================================
 nf-core/diaproteomics Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/diaproteomics
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/diaproteomics --dia_mzmls '*.mzML' --spectral_lib '*.pqp' --irts '*.pqp' --swath_windows '*.txt' -profile standard,docker

    Mandatory arguments:
      --dia_mzmls                       Path to input data (must be surrounded with quotes)
      --swath_windows                   Path to swath_windows.txt file, containing swath window mz ranges
      -profile                          Configuration profile to use. Can use multiple (comma separated)
                                        Available: standard, conda, docker, singularity, awsbatch, test
    DIA Mass Spectrometry Search:
      --spectral_lib                    Path to spectral library input file (pqp)
      --irts                            Path to internal retention time standards (pqp)
      --irt_min_rsq			Minimal rsq error for irt RT alignment (default=0.95)
      --irt_alignment_method            Method for irt RT alignment ('linear','lowess')
      --generate_spectral_lib           Set flag if spectral lib should be generated from provided DDA data (pepXML and mzML)
      --dda_pepxmls                     Path to DDA pepXML input for library generation
      --dda_mzmls                       Path to DDA mzML input for library generation
      --skip_decoy_generation           Use a spectral library that already includes decoy sequences
      --decoy_method                    Method for generating decoys ('shuffle','pseudo-reverse','reverse','shift')
      --min_transitions                 Minimum peptide length for filtering
      --max_transitions                 Maximum peptide length for filtering
      --mz_extraction_window            Mass tolerance for transition extraction (ppm)
      --rt_extraction_window            RT window for transition extraction (seconds)
      --pyprophet_classifier            Classifier used for target / decoy separation ('LDA','XGBoost')
      --pyprophet_fdr_ms_level          MS Level of FDR calculation ('ms1', 'ms2', 'ms1ms2')
      --pyprophet_global_fdr_level      Level of FDR calculation ('peptide', 'protein')
      --pyprophet_peakgroup_fdr         Threshold for FDR filtering
      --pyprophet_peptide_fdr           Threshold for global Peptide FDR
      --pyprophet_protein_fdr           Threshold for global Protein FDR
      --DIAlignR_global_align_FDR         DIAlignR global Aligment FDR threshold
      --DIAlignR_analyte_FDR             DIAlignR Analyte FDR threshold
      --DIAlignR_unalign_FDR             DIAlignR UnAligment FDR threshold
      --DIAlignR_align_FDR               DIAlignR Aligment FDR threshold
      --prec_charge                     Precursor charge (eg. "2:3")
      --force_option                    Force the Analysis despite severe warnings

    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --publish_dir_mode [str]        Mode for publishing results in the output directory. Available: symlink, rellink, link, copy, copyNoFollow, move (Default: copy)
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful
      --max_multiqc_email_size [str]  Threshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */


// Has the run name been specified by the user?
// this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

// Check AWS batch settings
if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)
ch_output_docs_images = file("$baseDir/docs/images/", checkIfExists: true)

// Validate inputs
params.dia_mzmls = params.dia_mzmls ?: { log.error "No dia mzml data provided. Make sure you have used the '--dia_mzmls' option."; exit 1 }()
params.swath_windows = params.swath_windows ?: { log.error "No swath windows provided. Make sure you have used the '--swath_windows' option."; exit 1 }()
params.irts = params.irts ?: { log.error "No internal retention time standards provided. Make sure you have used the '--irts' option."; exit 1 }()
params.outdir = params.outdir ?: { log.warn "No output directory provided. Will put the results into './results'"; return "./results" }()

Channel.fromPath( params.dia_mzmls )
        .ifEmpty { exit 1, "Cannot find any mzmls matching: ${params.dia_mzmls}\nNB: Path needs to be enclosed in quotes!" }
        .set { input_mzmls }

Channel.fromPath( params.swath_windows)
        .ifEmpty { exit 1, "Cannot find any swath_windows matching: ${params.swath_windows}\nNB: Path needs to be enclosed in quotes!" }
        .set { input_swath_windows }

Channel.fromPath( params.irts)
        .ifEmpty { exit 1, "Cannot find any irts matching: ${params.irts}\nNB: Path needs to be enclosed in quotes!" }
        .set { input_irts }


/*
 * Create a channel for input spectral library
 */
if( params.generate_spectral_lib) {

    input_spectral_lib = Channel.empty()

} else if( !params.skip_decoy_generation) {
    Channel
        .fromPath( params.spectral_lib )
        .ifEmpty { exit 1, "params.spectral_lib was empty - no input spectral library supplied" }
        .set { input_lib_nd }

    input_lib = Channel.empty()
    input_lib_1 = Channel.empty()

} else {
    Channel
        .fromPath( params.spectral_lib )
        .ifEmpty { exit 1, "params.spectral_lib was empty - no input spectral library supplied" }
        .into { input_lib; input_lib_1 }

    input_lib_nd = Channel.empty()

}


// Force option
if (params.force_option){
 force_option='-force'
} else {
 force_option=''
}


// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
summary['mzMLs']        = params.dia_mzmls
summary['Spectral Library']    = params.spectral_lib
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Profile Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Profile Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config Profile URL']         = params.config_profile_url
summary['Config Files'] = workflow.configFiles.join(', ')
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-diaproteomics-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/diaproteomics Workflow Summary'
    section_href: 'https://github.com/nf-core/diaproteomics'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }


/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}


/*
 * STEP 0 - Spectral Library Generation using EasyPQP
 */
//
// TODO:
// 1) (option) mzid to idXML
// 2) easypqp convert —pepxml … —spectra …
// 3) easypqp library
//


/*
 * STEP 0.5 - Decoy Generation for Spectral Library
 */
process generate_decoys_for_spectral_library {
    publishDir "${params.outdir}/"

    input:
     file lib_file_nd from input_lib_nd

    output:
     file "${lib_file_nd.baseName}_decoy.pqp" into (input_lib_decoy, input_lib_decoy_1)

    when:
     !params.skip_decoy_generation

    script:
     """
     OpenSwathDecoyGenerator -in ${lib_file_nd} \\
                             -method ${params.decoy_method} \\
                             -out "${lib_file_nd.baseName}_decoy.pqp" \\
     """
}


/*
 * STEP 1 - OpenSwathWorkFlow
 */
process run_openswathworkflow {
    publishDir "${params.outdir}/"

    label 'process_medium'

    input:
     file mzml_file from input_mzmls
     file swath_file from input_swath_windows.first()
     file lib_file from input_lib_decoy.mix(input_lib).first()
     file irt_file from input_irts.first()

    output:
     file "${mzml_file.baseName}_chrom.mzML" into chromatogram_files
     file "${mzml_file.baseName}.osw" into osw_files

    script:
     """
     OpenSwathWorkflow -in ${mzml_file} \\
                       -tr ${lib_file} \\
                       -swath_windows_file ${swath_file} \\
                       -sort_swath_maps \\
                       -tr_irt ${irt_file} \\
                       -min_rsq ${params.irt_min_rsq} \\
                       -out_osw ${mzml_file.baseName}.osw \\
                       -out_chrom ${mzml_file.baseName}_chrom.mzML \\
                       -mz_extraction_window ${params.mz_extraction_window} \\
                       -mz_extraction_window_unit 'ppm' \\
                       -mz_extraction_window_ms1_unit 'ppm' \\
                       -rt_extraction_window ${params.rt_extraction_window} \\
                       -RTNormalization:alignmentMethod ${params.irt_alignment_method} \\
                       -RTNormalization:estimateBestPeptides \\
                       -RTNormalization:outlierMethod none \\
                       -mz_correction_function quadratic_regression_delta_ppm \\
                       -use_ms1_traces \\
                       -Scoring:stop_report_after_feature 5 \\
                       -Scoring:TransitionGroupPicker:compute_peak_quality false \\
                       -Scoring:Scores:use_ms1_mi \\
                       -Scoring:Scores:use_mi_score \\
                       -batchSize 1000 \\
                       -Scoring:DIAScoring:dia_nr_isotopes 3 \\
                       -enable_uis_scoring \\
                       -Scoring:uis_threshold_sn -1 \\
                       -threads ${task.cpus} \\
                       ${force_option} \\                       
     """
}


/*
 * STEP 2 - Pyprophet merging of OpenSwath results
 */
process merge_openswath_output {
    publishDir "${params.outdir}/"

    input:
     file all_osws from osw_files.collect{it}
     file lib_file_1 from input_lib_decoy_1.mix(input_lib_1).first()

    output:
     file "osw_file_merged.osw" into merged_osw_file

    script:
     """
     pyprophet merge --template=${lib_file_1} \\
                     --out=osw_file_merged.osw \\
                     ${all_osws} \\
     """
}


/*
 * STEP 3 - Pyprophet FDR Scoring
 */
process run_fdr_scoring {
    publishDir "${params.outdir}/"

    input:
     file merged_osw from merged_osw_file

    output:
     file "${merged_osw.baseName}_scored_merged.osw" into (merged_osw_scored, merged_osw_scored_for_pyprophet)

    when:
     params.pyprophet_global_fdr_level==''

    script:
     """
     pyprophet score --in=${merged_osw} \\
                     --level=${params.pyprophet_fdr_ms_level} \\
                     --out=${merged_osw.baseName}_scored_merged.osw \\
                     --classifier=${params.pyprophet_classifier} \\
                     --threads=${task.cpus} \\
     """
}


/*
 * STEP 4 - Pyprophet global FDR Scoring
 */
process run_global_fdr_scoring {
    publishDir "${params.outdir}/"

    input:
     file scored_osw from merged_osw_file

    output:
     file "${scored_osw.baseName}_global_merged.osw" into merged_osw_scored_global

    when:
     params.pyprophet_global_fdr_level!=''

    script:
     """
     pyprophet score --in=${scored_osw} \\
                     --level=${params.pyprophet_fdr_ms_level} \\
                     --out=${scored_osw.baseName}_scored.osw \\
                     --threads=${task.cpus} \\

     pyprophet ${params.pyprophet_global_fdr_level} --in=${scored_osw.baseName}_scored.osw \\
                                                    --out=${scored_osw.baseName}_global_merged.osw \\
                                                    --context=global \\
     """
}


/*
 * STEP 5 - Pyprophet Export
 */
process export_pyprophet_results {
    publishDir "${params.outdir}/"

    input:
     file global_osw from merged_osw_scored.mix(merged_osw_scored_global)

    output:
     file "*.tsv" into pyprophet_results

    script:
     """
     pyprophet export --in=${global_osw} \\
                      --max_rs_peakgroup_qvalue=${params.pyprophet_peakgroup_fdr} \\
                      --max_global_peptide_qvalue=${params.pyprophet_peptide_fdr} \\
                      --max_global_protein_qvalue=${params.pyprophet_protein_fdr} \\
                      --out=legacy.tsv \\
     """
}


/*
 * STEP 6 - Index Chromatogram mzMLs
 */
process index_chromatograms {
    publishDir "${params.outdir}/"

    input:
     file chrom_file_noindex from chromatogram_files

    output:
     file "${chrom_file_noindex.baseName.split('_chrom')[0]}.chrom.mzML" into chromatogram_files_indexed

    script:
     """
     FileConverter -in ${chrom_file_noindex} \\
                   -out ${chrom_file_noindex.baseName.split('_chrom')[0]}.chrom.mzML \\
     """
}


/*
 * STEP 7 - Align DIA Chromatograms using DIAlignR
 */
process align_dia_runs {
    publishDir "${params.outdir}/"

    input:
     file pyresults from merged_osw_scored_for_pyprophet
     file chrom_files_index from chromatogram_files_indexed.collect()

    output:
     file "DIAlignR.csv" into DIALignR_result

    script:
     """
     mkdir osw
     mv ${pyresults} osw/
     mkdir mzml
     mv *.chrom.mzML mzml/

     DIAlignR.R ${params.DIAlignR_global_align_FDR} ${params.DIAlignR_analyte_FDR} ${params.DIAlignR_unalign_FDR} ${params.DIAlignR_align_FDR}
     """
}


/*
 * Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode

    input:
    file output_docs from ch_output_docs
    file images from ch_output_docs_images

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/diaproteomics] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/diaproteomics] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.max_multiqc_email_size)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/diaproteomics] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/diaproteomics] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/diaproteomics] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            def mail_cmd = [ 'mail', '-s', subject, '--content-type=text/html', email_address ]
            if ( mqc_report.size() <= params.max_multiqc_email_size.toBytes() ) {
              mail_cmd += [ '-A', mqc_report ]
            }
            mail_cmd.execute() << email_html
            log.info "[nf-core/diaproteomics] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/diaproteomics]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/diaproteomics]${c_red} Pipeline completed with errors${c_reset}-"
    }

}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/diaproteomics v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
